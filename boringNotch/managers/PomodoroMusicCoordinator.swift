//
//  PomodoroMusicCoordinator.swift
//  boringNotch
//

import AppKit
import Defaults
import Foundation

/// Coordinates YouTube Music playback with Pomodoro timer phases.
///
/// Navigation strategy (tried in order, stops at first success):
///
///   1. POST /api/v1/navigate  — available only when the Navigate plugin is enabled
///      in YTMD and the API Server exposes it.
///
///   2. GET /api/v1/queue  →  POST /api/v1/queue  →  PATCH /api/v1/queue
///      • GET: find which queue item has `selected = true` → currentIndex
///      • POST body: { videoId, insertPosition: "INSERT_AFTER_CURRENT_VIDEO" [, playlistId] }
///        → our track lands at currentIndex + 1
///      • PATCH body: { index: currentIndex + 1 }
///        → YTMD jumps directly to that track and starts playing it
///
///   3. Silent continue — play/shuffle from whatever is already loaded.
///
/// URL → API payload:
///   watch?v=V          → { videoId: V, insertPosition: INSERT_AFTER_CURRENT_VIDEO }
///   watch?v=V&list=L   → { videoId: V, insertPosition: ..., playlistId: L }
///   playlist?list=L    → rejected (no video ID); the Settings UI warns the user.
///
/// The `si` share-tracking parameter is stripped before parsing.
final class PomodoroMusicCoordinator {

    // MARK: - YTMD config
    private let baseURL  = YouTubeMusicConfiguration.default.baseURL
    private let bundleID = YouTubeMusicConfiguration.default.bundleIdentifier
    private var cachedToken: String?

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

        let urlString: String
        let shuffle: Bool

        switch phase {
        case .work:
            urlString = Defaults[.pomodoroYTMWorkURL]
            shuffle   = Defaults[.pomodoroYTMWorkShuffle]
        case .shortBreak:
            urlString = Defaults[.pomodoroYTMBreakURL]
            shuffle   = Defaults[.pomodoroYTMBreakShuffle]
        case .longBreak:
            urlString = Defaults[.pomodoroYTMLongBreakURL]
            shuffle   = Defaults[.pomodoroYTMLongBreakShuffle]
        }

        pendingTask?.cancel()
        pendingTask = Task {
            await executePhaseTransition(urlString: urlString, shuffle: shuffle)
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

    // MARK: - Phase Transition

    private func executePhaseTransition(urlString: String, shuffle: Bool) async {
        guard !Task.isCancelled else { return }

        guard isYTMDRunning() else {
            print("[PomodoroMusicCoordinator] YTMD not running — skipping")
            return
        }

        let titleBefore = await currentSongTitle()

        // Pause current playback while we switch
        await sendCommand("/pause")
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        var navigated = false

        if !urlString.isEmpty, let raw = URL(string: urlString) {
            let url = stripShareParam(raw)

            // Strategy 1: API navigate endpoint (requires Navigate plugin)
            navigated = await navigateViaAPI(to: url)

            // Strategy 2: GET queue → POST (INSERT_AFTER_CURRENT_VIDEO) → PATCH index
            if !navigated {
                navigated = await navigateViaQueueInsert(url: url)
            }

            if navigated {
                // Give YTMD time to load / buffer the track
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }

                let titleAfter = await currentSongTitle()
                if let before = titleBefore, let after = titleAfter {
                    if before != after {
                        print("[PomodoroMusicCoordinator] ✓ Track changed: '\(before)' → '\(after)'")
                    } else {
                        print("[PomodoroMusicCoordinator] ✗ Track unchanged ('\(after)')")
                        print("[PomodoroMusicCoordinator]   setQueueIndex may have succeeded but track is loading.")
                    }
                }
            } else {
                print("[PomodoroMusicCoordinator] All navigation strategies exhausted — continuing current content")
            }
            guard !Task.isCancelled else { return }
        }

        // Ensure playback is running
        await sendCommand("/play")

        // Sync shuffle state
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }

        if let current = await getShuffleState(), current != shuffle {
            await sendCommand("/shuffle")
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

        print("[PomodoroMusicCoordinator] Strategy 1 (navigate): success")
        return true
    }

    // MARK: - Strategy 2: Queue GET → POST INSERT_AFTER_CURRENT → PATCH index

    private func navigateViaQueueInsert(url: URL) async -> Bool {
        guard let payload = queuePayload(for: url) else {
            print("[PomodoroMusicCoordinator] Queue strategy: unrecognised URL — skipping")
            return false
        }
        guard let token = await getToken() else { return false }

        // Step A: find the currently selected queue index
        let currentIndex = await selectedQueueIndex(token: token)
        let targetIndex  = (currentIndex ?? 0) + 1
        print("[PomodoroMusicCoordinator] Current queue index: \(currentIndex.map(String.init) ?? "unknown") → inserting at \(targetIndex)")

        // Step B: POST our track with INSERT_AFTER_CURRENT_VIDEO
        guard let queueURL = URL(string: "\(baseURL)/api/v1/queue") else { return false }
        var postReq = URLRequest(url: queueURL)
        postReq.httpMethod = "POST"
        postReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        postReq.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let (postData, postResp) = try? await session.data(for: postReq),
              let postHTTP = postResp as? HTTPURLResponse
        else {
            print("[PomodoroMusicCoordinator] Queue POST: no response")
            return false
        }

        let postBody = String(data: postData, encoding: .utf8) ?? ""
        print("[PomodoroMusicCoordinator] Queue POST payload: \(payload)")
        print("[PomodoroMusicCoordinator] Queue POST → HTTP \(postHTTP.statusCode)\(postBody.isEmpty ? "" : " \(postBody)")")

        if postHTTP.statusCode == 401 { cachedToken = nil }
        guard (200..<300).contains(postHTTP.statusCode) else { return false }

        // Step C: jump directly to our track via setQueueIndex
        try? await Task.sleep(for: .milliseconds(300))
        let jumped = await setQueueIndex(targetIndex, token: token)
        print("[PomodoroMusicCoordinator] PATCH /queue { index: \(targetIndex) } → \(jumped ? "success" : "failed")")

        return jumped
    }

    // MARK: - Queue Helpers

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
            // Handle both playlistPanelVideoRenderer and the wrapper variant
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

    /// PATCH /api/v1/queue { "index": N } — tells YTMD to jump to and play that queue position.
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

    // MARK: - URL Helpers

    /// Strip the `si` share-tracking parameter YouTube Music appends to share links.
    private func stripShareParam(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.queryItems = c.queryItems?.filter { $0.name != "si" }
        return c.url ?? url
    }

    /// Build the POST /api/v1/queue payload.
    ///
    /// Always includes `insertPosition: INSERT_AFTER_CURRENT_VIDEO` so the track
    /// lands immediately after the current one (at currentIndex + 1).
    ///
    /// Supported URL shapes:
    ///   watch?v=V         → { videoId: V, insertPosition }
    ///   watch?v=V&list=L  → { videoId: V, insertPosition, playlistId: L }
    ///
    /// playlist?list=L is rejected — it has no video ID for the queue API.
    private func queuePayload(for url: URL) -> [String: Any]? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = url.host, host.contains("music.youtube.com")
        else { return nil }

        let items = components.queryItems ?? []

        if url.path.contains("/watch"),
           let videoId = items.first(where: { $0.name == "v" })?.value {
            var payload: [String: Any] = [
                "videoId": videoId,
                "insertPosition": "INSERT_AFTER_CURRENT_VIDEO"
            ]
            if let listId = items.first(where: { $0.name == "list" })?.value {
                payload["playlistId"] = listId
            }
            return payload
        }

        if url.path.contains("/playlist") {
            let listId = items.first(where: { $0.name == "list" })?.value ?? ""
            print("[PomodoroMusicCoordinator] Playlist-only URL — no video ID for queue API.")
            print("[PomodoroMusicCoordinator]   Use: watch?v=ANY_TRACK&list=\(listId)")
            return nil
        }

        return nil
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
