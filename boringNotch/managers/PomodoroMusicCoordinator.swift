//
//  PomodoroMusicCoordinator.swift
//  boringNotch
//

import AppKit
import Defaults
import Foundation

/// Coordinates YouTube Music playback with Pomodoro timer phases.
///
/// ## Navigation strategies (tried in order)
///
///   1. POST /api/v1/navigate  — requires the "Navigate" plugin in YTMD.
///      Works with any URL including full playlist links. This is the only
///      path that loads an entire playlist into YTMD's context.
///
///   2. GET /api/v1/queue  →  POST /api/v1/queue  →  PATCH /api/v1/queue
///      Works for watch?v=V (single video or video-within-playlist).
///      The `playlistId` field in POST /queue is accepted by the schema but
///      is NOT forwarded to the renderer by YTMD's song-controls layer
///      (confirmed from source), so playlist context cannot be loaded this way.
///
///   3. Silent continue (plays whatever is already loaded).
///
/// ## Queue clear
///   DELETE /api/v1/queue (no index) is called at the start of every phase
///   transition — after pausing, before inserting. This removes stale queue
///   items that accumulated from previous cycles or the user's prior session.
///   The currently playing track is unaffected (YouTube Music keeps it buffered).
///
/// ## Seek-to-zero
///   YouTube Music caches playback position for partially-watched videos.
///   When a phase's "Resume where I left off" toggle is OFF, the coordinator
///   explicitly seeks to 0 after the track loads (~1.2 s), overriding the
///   cached position.
///
/// ## Resume where I left off
///   When a phase's toggle is ON, the current videoId + elapsedSeconds are
///   captured from GET /api/v1/song before leaving that phase. On re-entry,
///   the coordinator navigates to the saved videoId and seeks to the saved
///   position. Saved state is cleared when timerReset() is called.
///
/// ## Shuffle + playlist
///   After navigation succeeds, if shuffle is on and the URL contains both
///   v= and list= parameters (i.e., a video inside a playlist), the coordinator
///   enables shuffle and calls /next once to land on a random track.
///   This only works reliably when navigation used Strategy 1 (Navigate plugin),
///   because only that strategy loads the full playlist queue into YTMD.
///
/// ## URL shapes
///   watch?v=V          → queue payload { videoId: V }
///   watch?v=V&list=L   → queue payload { videoId: V, playlistId: L } (playlistId is cosmetic only in queue path)
///   playlist?list=L    → rejected for queue path; navigate path handles it if plugin is enabled
final class PomodoroMusicCoordinator {

    // MARK: - Saved position snapshot

    private struct PhaseSnapshot {
        let videoId: String
        let elapsedSeconds: Double
        let title: String
    }

    // MARK: - State

    private let baseURL  = YouTubeMusicConfiguration.default.baseURL
    private let bundleID = YouTubeMusicConfiguration.default.bundleIdentifier
    private var cachedToken: String?

    private var currentPhase: PomodoroPhase?
    private var savedWork:      PhaseSnapshot?
    private var savedBreak:     PhaseSnapshot?
    private var savedLongBreak: PhaseSnapshot?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    private var pendingTask: Task<Void, Never>?

    // MARK: - Phase Events

    func phaseStarted(_ phase: PomodoroPhase) {
        guard Defaults[.pomodoroYTMEnabled] else { return }

        let leavingPhase = currentPhase
        currentPhase = phase

        let urlString: String
        let shuffle: Bool
        let resumeEnabled: Bool

        switch phase {
        case .work:
            urlString     = Defaults[.pomodoroYTMWorkURL]
            shuffle       = Defaults[.pomodoroYTMWorkShuffle]
            resumeEnabled = Defaults[.pomodoroYTMWorkResume]
        case .shortBreak:
            urlString     = Defaults[.pomodoroYTMBreakURL]
            shuffle       = Defaults[.pomodoroYTMBreakShuffle]
            resumeEnabled = Defaults[.pomodoroYTMBreakResume]
        case .longBreak:
            urlString     = Defaults[.pomodoroYTMLongBreakURL]
            shuffle       = Defaults[.pomodoroYTMLongBreakShuffle]
            resumeEnabled = Defaults[.pomodoroYTMLongBreakResume]
        }

        let savedSnapshot: PhaseSnapshot? = resumeEnabled ? snapshot(for: phase) : nil

        pendingTask?.cancel()
        pendingTask = Task {
            await executePhaseTransition(
                phase: phase,
                leavingPhase: leavingPhase,
                urlString: urlString,
                shuffle: shuffle,
                savedSnapshot: savedSnapshot
            )
        }
    }

    func timerPaused() {
        guard Defaults[.pomodoroYTMEnabled] else { return }
        pendingTask?.cancel()
        Task { await sendCommand("/pause") }
    }

    func timerResumed() {
        guard Defaults[.pomodoroYTMEnabled] else { return }
        Task { await sendCommand("/play") }
    }

    func timerReset() {
        savedWork      = nil
        savedBreak     = nil
        savedLongBreak = nil
        currentPhase   = nil
    }

    // MARK: - Snapshot Helpers

    private func snapshot(for phase: PomodoroPhase) -> PhaseSnapshot? {
        switch phase {
        case .work:       return savedWork
        case .shortBreak: return savedBreak
        case .longBreak:  return savedLongBreak
        }
    }

    private func storeSnapshot(_ snap: PhaseSnapshot, for phase: PomodoroPhase) {
        switch phase {
        case .work:       savedWork      = snap
        case .shortBreak: savedBreak     = snap
        case .longBreak:  savedLongBreak = snap
        }
    }

    private func resumeToggleEnabled(for phase: PomodoroPhase) -> Bool {
        switch phase {
        case .work:       return Defaults[.pomodoroYTMWorkResume]
        case .shortBreak: return Defaults[.pomodoroYTMBreakResume]
        case .longBreak:  return Defaults[.pomodoroYTMLongBreakResume]
        }
    }

    // MARK: - Phase Transition

    private func executePhaseTransition(
        phase: PomodoroPhase,
        leavingPhase: PomodoroPhase?,
        urlString: String,
        shuffle: Bool,
        savedSnapshot: PhaseSnapshot?
    ) async {
        guard !Task.isCancelled else { return }
        guard isYTMDRunning() else {
            print("[PomodoroMusicCoordinator] YTMD not running — skipping")
            return
        }

        // Save position for the phase we're leaving (if its resume toggle is on)
        if let leaving = leavingPhase, resumeToggleEnabled(for: leaving) {
            if let snap = await captureCurrentSong() {
                storeSnapshot(snap, for: leaving)
                print("[PomodoroMusicCoordinator] Saved \(leaving) position: \(Int(snap.elapsedSeconds))s into '\(snap.title)'")
            }
        }

        // Pause while we switch
        await sendCommand("/pause")
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        // Clear all queued items so stale tracks from prior cycles don't interfere.
        // The currently buffered/playing track is unaffected by the clear.
        let cleared = await clearQueue()
        print("[PomodoroMusicCoordinator] Queue cleared → \(cleared ? "✓" : "✗")")
        if cleared {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }

        var navigated = false
        var didResume = false
        var didShuffleSkim = false

        // ── Resume path ────────────────────────────────────────────────────────
        if let snap = savedSnapshot {
            print("[PomodoroMusicCoordinator] Resuming \(phase): '\(snap.title)' at \(Int(snap.elapsedSeconds))s")
            navigated = await navigateViaQueueInsertVideoId(snap.videoId, playlistId: nil)
            if navigated {
                // Buffer time before seeking
                try? await Task.sleep(for: .milliseconds(1400))
                guard !Task.isCancelled else { return }
                let sought = await seekTo(seconds: snap.elapsedSeconds)
                print("[PomodoroMusicCoordinator] Seek \(Int(snap.elapsedSeconds))s → \(sought ? "✓" : "✗")")
                didResume = true
            }
        }

        // ── Normal navigation path ──────────────────────────────────────────────
        if !navigated, !urlString.isEmpty, let raw = URL(string: urlString) {
            let url = stripShareParam(raw)

            // Strategy 1: Navigate plugin (handles playlists, any URL)
            navigated = await navigateViaAPI(to: url)

            // Strategy 2: Queue insert (single video only; playlistId is cosmetic in this path)
            if !navigated {
                navigated = await navigateViaQueueInsert(url: url)
            }
        }

        guard !Task.isCancelled else { return }

        if navigated && !didResume {
            // Give YTMD time to buffer the track before checking / seeking
            try? await Task.sleep(for: .milliseconds(1000))
            guard !Task.isCancelled else { return }

            let titleAfter = await currentSongTitle()
            print("[PomodoroMusicCoordinator] Now playing: '\(titleAfter ?? "?")'")
        } else if !navigated {
            print("[PomodoroMusicCoordinator] All navigation strategies exhausted — continuing current content")
        }

        // Start playback
        await sendCommand("/play")

        // Sync shuffle state
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }

        if let currentShuffle = await getShuffleState(), currentShuffle != shuffle {
            await sendCommand("/shuffle")
        }

        // Shuffle + playlist: skip to a random track.
        // This only produces genuine randomisation when Strategy 1 (navigate) was used,
        // because only the navigate endpoint loads the full playlist into YTMD.
        if navigated && !didResume && shuffle,
           !urlString.isEmpty,
           let raw = URL(string: urlString),
           hasPlaylistContext(stripShareParam(raw)) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await sendCommand("/next")
            didShuffleSkim = true
            print("[PomodoroMusicCoordinator] Shuffle-skip fired")

            // Wait for the skipped-to track to load before seeking
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
        }

        // Seek to 0 when resume is OFF (overrides YouTube's cached position for this video).
        // Not needed after a resume (already seeked to saved position) or when there
        // was no navigation (no track change happened).
        if navigated && !didResume {
            let sought = await seekTo(seconds: 0)
            print("[PomodoroMusicCoordinator] Seek-to-zero (resume OFF)\(didShuffleSkim ? " after shuffle-skip" : "") → \(sought ? "✓" : "✗")")
        }
    }

    // MARK: - Strategy 1: API Navigate

    private func navigateViaAPI(to url: URL) async -> Bool {
        guard let token = await getToken() else { return false }
        guard let endpoint = URL(string: "\(baseURL)/api/v1/navigate") else { return false }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["url": url.absoluteString])

        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        if http.statusCode == 401 { cachedToken = nil }
        guard (200..<300).contains(http.statusCode) else { return false }

        print("[PomodoroMusicCoordinator] Strategy 1 (navigate): ✓")
        return true
    }

    // MARK: - Strategy 2: Queue INSERT_AFTER_CURRENT → PATCH index

    private func navigateViaQueueInsert(url: URL) async -> Bool {
        guard let payload = queuePayload(for: url) else {
            print("[PomodoroMusicCoordinator] Queue strategy: unrecognised/playlist-only URL — skipping")
            return false
        }
        return await insertAndJump(payload: payload)
    }

    private func navigateViaQueueInsertVideoId(_ videoId: String, playlistId: String?) async -> Bool {
        var payload: [String: Any] = ["videoId": videoId]
        if let listId = playlistId { payload["playlistId"] = listId }
        return await insertAndJump(payload: payload)
    }

    private func insertAndJump(payload: [String: Any]) async -> Bool {
        guard let token = await getToken() else { return false }

        // Find the currently selected queue index (post-clear, this is usually 0 or nil)
        let currentIndex = await selectedQueueIndex(token: token)

        // Choose insert position and target index based on whether there's a current item
        var fullPayload = payload
        let targetIndex: Int
        if let cur = currentIndex {
            fullPayload["insertPosition"] = "INSERT_AFTER_CURRENT_VIDEO"
            targetIndex = cur + 1
        } else {
            fullPayload["insertPosition"] = "INSERT_AT_END"
            targetIndex = 0
        }

        print("[PomodoroMusicCoordinator] Queue idx: \(currentIndex.map(String.init) ?? "empty") → inserting at \(targetIndex)")

        guard let queueURL = URL(string: "\(baseURL)/api/v1/queue") else { return false }
        var postReq = URLRequest(url: queueURL)
        postReq.httpMethod = "POST"
        postReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        postReq.httpBody = try? JSONSerialization.data(withJSONObject: fullPayload)

        guard let (postData, postResp) = try? await session.data(for: postReq),
              let postHTTP = postResp as? HTTPURLResponse
        else {
            print("[PomodoroMusicCoordinator] Queue POST: no response")
            return false
        }

        let postBody = String(data: postData, encoding: .utf8) ?? ""
        print("[PomodoroMusicCoordinator] Queue POST → HTTP \(postHTTP.statusCode)\(postBody.isEmpty ? "" : " \(postBody)")")

        if postHTTP.statusCode == 401 { cachedToken = nil }
        guard (200..<300).contains(postHTTP.statusCode) else { return false }

        try? await Task.sleep(for: .milliseconds(300))
        let jumped = await setQueueIndex(targetIndex, token: token)
        print("[PomodoroMusicCoordinator] PATCH /queue { index: \(targetIndex) } → \(jumped ? "✓" : "✗")")
        return jumped
    }

    // MARK: - Queue Helpers

    /// DELETE /api/v1/queue — clears all queued items; current track continues playing.
    @discardableResult
    private func clearQueue() async -> Bool {
        guard let token = await getToken(),
              let url = URL(string: "\(baseURL)/api/v1/queue")
        else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return false }
        if http.statusCode == 401 { cachedToken = nil }
        return (200..<300).contains(http.statusCode)
    }

    /// Returns the 0-based index of the item with `selected == true` in the queue.
    private func selectedQueueIndex(token: String) async -> Int? {
        guard let url = URL(string: "\(baseURL)/api/v1/queue") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await session.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else { return nil }

        return items.firstIndex { item in
            if let r = item["playlistPanelVideoRenderer"] as? [String: Any] {
                return r["selected"] as? Bool == true
            }
            if let wrapper = item["playlistPanelVideoWrapperRenderer"] as? [String: Any],
               let primary = wrapper["primaryRenderer"] as? [String: Any],
               let r = primary["playlistPanelVideoRenderer"] as? [String: Any] {
                return r["selected"] as? Bool == true
            }
            return false
        }
    }

    /// PATCH /api/v1/queue { "index": N } — jumps YTMD to that queue position immediately.
    private func setQueueIndex(_ index: Int, token: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/v1/queue") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["index": index])

        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return false }
        if http.statusCode == 401 { cachedToken = nil }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Song State Capture / Seek

    private func captureCurrentSong() async -> PhaseSnapshot? {
        guard let token = await getToken(),
              let url = URL(string: "\(baseURL)/api/v1/song")
        else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await session.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let videoId = json["videoId"] as? String
        else { return nil }

        let elapsed: Double
        if let e = json["elapsedSeconds"] as? Double      { elapsed = e }
        else if let e = json["elapsedSeconds"] as? Int    { elapsed = Double(e) }
        else                                               { elapsed = 0 }

        let title = json["title"] as? String ?? videoId
        return PhaseSnapshot(videoId: videoId, elapsedSeconds: elapsed, title: title)
    }

    @discardableResult
    private func seekTo(seconds: Double) async -> Bool {
        guard let token = await getToken(),
              let url = URL(string: "\(baseURL)/api/v1/seek-to")
        else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["seconds": seconds])

        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return false }
        if http.statusCode == 401 { cachedToken = nil }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - URL Helpers

    private func stripShareParam(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.queryItems = c.queryItems?.filter { $0.name != "si" }
        return c.url ?? url
    }

    /// Builds the POST /api/v1/queue payload for a watch?v=... URL.
    /// Returns nil for playlist-only URLs — those can only be handled by the navigate endpoint.
    private func queuePayload(for url: URL) -> [String: Any]? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = url.host, host.contains("music.youtube.com")
        else { return nil }

        let items = components.queryItems ?? []

        if url.path.contains("/watch"),
           let videoId = items.first(where: { $0.name == "v" })?.value {
            var payload: [String: Any] = ["videoId": videoId]
            if let listId = items.first(where: { $0.name == "list" })?.value {
                payload["playlistId"] = listId
            }
            return payload
        }

        if url.path.contains("/playlist") {
            print("[PomodoroMusicCoordinator] Playlist-only URL: queue path cannot load playlists.")
            print("[PomodoroMusicCoordinator]   Enable the Navigate plugin in YTMD for playlist support.")
            return nil
        }

        return nil
    }

    /// True when the URL carries both a video ID and a playlist — meaning YTMD has
    /// playlist context loaded and shuffle + /next will be effective.
    private func hasPlaylistContext(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let items = components.queryItems ?? []
        return items.contains(where: { $0.name == "v" }) &&
               items.contains(where: { $0.name == "list" })
    }

    // MARK: - Diagnostics

    private func currentSongTitle() async -> String? {
        guard let token = await getToken(),
              let url = URL(string: "\(baseURL)/api/v1/song")
        else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await session.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["title"] as? String
    }

    // MARK: - YTMD HTTP Commands

    private func getToken() async -> String? {
        if let t = cachedToken { return t }
        guard let url = URL(string: "\(baseURL)/auth/boringNotch") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        guard let (data, _) = try? await session.data(for: req),
              let resp = try? JSONDecoder().decode(AuthResponse.self, from: data)
        else {
            print("[PomodoroMusicCoordinator] Auth failed")
            return nil
        }
        cachedToken = resp.accessToken
        return resp.accessToken
    }

    @discardableResult
    private func sendCommand(_ endpoint: String, method: String = "POST") async -> Bool {
        guard let token = await getToken(),
              let url = URL(string: "\(baseURL)/api/v1\(endpoint)")
        else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return false }
        if http.statusCode == 401 { cachedToken = nil }
        guard (200..<300).contains(http.statusCode) else {
            print("[PomodoroMusicCoordinator] \(endpoint): HTTP \(http.statusCode)")
            return false
        }
        return true
    }

    private func getShuffleState() async -> Bool? {
        guard let token = await getToken(),
              let url = URL(string: "\(baseURL)/api/v1/shuffle")
        else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? Bool
        else { return nil }
        return state
    }

    private func isYTMDRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}
