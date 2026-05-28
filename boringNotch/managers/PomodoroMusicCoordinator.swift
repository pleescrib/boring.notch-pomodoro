//
//  PomodoroMusicCoordinator.swift
//  boringNotch
//

import AppKit
import Defaults
import Foundation

/// Coordinates YouTube Music playback with Pomodoro timer phases.
///
/// Targets YTMD directly via its companion HTTP API (localhost:26538).
///
/// Navigation strategy (tried in order):
///   1. POST /api/v1/navigate  — works in YTMD builds that have the Navigate plugin
///   2. DELETE /api/v1/queue → POST /api/v1/queue → POST /api/v1/next
///        • Clears the user queue so our track occupies the #1 slot, then /next plays it.
///        • DELETE is not documented in all YTMD versions; falls back gracefully if 404/405.
///   3. POST /api/v1/queue → POST /api/v1/next (without clearing)
///        • Our track lands wherever the queue places it; /next still skips one forward.
///        • Result may vary depending on existing queue depth.
///   4. Silent continue — keep whatever is already playing, apply shuffle only.
///
/// URL → payload mapping (for queue POST):
///   watch?v=V        → { videoId: V }
///   watch?v=V&list=L → { videoId: V, playlistId: L }
///   playlist?list=L  → not supported; user must supply a watch?v= link
///
/// The `si` share-tracking parameter is stripped before parsing.
final class PomodoroMusicCoordinator {

    // MARK: - YTMD companion API config
    private let baseURL  = YouTubeMusicConfiguration.default.baseURL
    private let bundleID = YouTubeMusicConfiguration.default.bundleIdentifier
    private var cachedToken: String?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    private var pendingTask: Task<Void, Never>?
    private var hasLoggedQueueOnce = false

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

        // Snapshot title for change detection
        let titleBefore = await currentSongTitle()

        // Pause before switching
        await sendCommand("/pause")
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        // Navigate if a URL was supplied
        var navigated = false
        if !urlString.isEmpty, let raw = URL(string: urlString) {
            let url = stripShareParam(raw)

            navigated = await navigateViaAPI(to: url)

            if !navigated {
                navigated = await navigateViaQueueClearAndSkip(url: url)
            }

            if navigated {
                // Give YTMD time to load the track
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }

                let titleAfter = await currentSongTitle()
                if let before = titleBefore, let after = titleAfter {
                    if before != after {
                        print("[PomodoroMusicCoordinator] ✓ Track changed: '\(before)' → '\(after)'")
                    } else {
                        print("[PomodoroMusicCoordinator] ✗ Track unchanged ('\(after)')")
                        print("[PomodoroMusicCoordinator]   Use watch?v=VIDEO_ID (not a playlist URL) for reliable switching.")
                    }
                }
            } else {
                print("[PomodoroMusicCoordinator] All navigation strategies failed — playing current content")
            }
            guard !Task.isCancelled else { return }
        }

        // Start playback for this phase
        await sendCommand("/play")

        // Sync shuffle state
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }

        if let current = await getShuffleState(), current != shuffle {
            await sendCommand("/shuffle")
        }
    }

    // MARK: - Navigation Strategies

    /// Strategy 1: POST /api/v1/navigate (requires Navigate plugin in YTMD)
    private func navigateViaAPI(to url: URL) async -> Bool {
        guard let token = await getToken() else { return false }
        guard let endpoint = URL(string: "\(baseURL)/api/v1/navigate") else { return false }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["url": url.absoluteString])

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }

        if http.statusCode == 401 { cachedToken = nil }
        guard (200..<300).contains(http.statusCode) else { return false }

        print("[PomodoroMusicCoordinator] Strategy 1 (navigate API): success")
        return true
    }

    /// Strategy 2 + 3: DELETE queue (to clear it), POST our track, POST /next.
    ///
    /// With an empty queue our track lands at position 1.
    /// A single /next call then skips the current track and plays ours.
    private func navigateViaQueueClearAndSkip(url: URL) async -> Bool {
        guard let payload = queuePayload(for: url) else {
            print("[PomodoroMusicCoordinator] Queue strategy: unrecognised URL shape — skipping")
            return false
        }
        guard let token = await getToken() else { return false }

        // Debug: log queue state once per app session
        if !hasLoggedQueueOnce {
            hasLoggedQueueOnce = true
            await logQueueState(token: token)
        }

        // Step A: try to clear the queue so our track will be first
        let cleared = await deleteQueue(token: token)
        if cleared {
            // Brief pause so YTMD processes the clear before we add
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Step B: add our track
        guard let endpoint = URL(string: "\(baseURL)/api/v1/queue") else { return false }
        var postReq = URLRequest(url: endpoint)
        postReq.httpMethod = "POST"
        postReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        postReq.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let (data, postResp) = try? await session.data(for: postReq),
              let postHTTP = postResp as? HTTPURLResponse
        else {
            print("[PomodoroMusicCoordinator] Queue POST: no response")
            return false
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        print("[PomodoroMusicCoordinator] Queue POST payload: \(payload)")
        print("[PomodoroMusicCoordinator] Queue POST → HTTP \(postHTTP.statusCode)\(body.isEmpty ? "" : " body: \(body)")")

        if postHTTP.statusCode == 401 { cachedToken = nil }
        guard (200..<300).contains(postHTTP.statusCode) else { return false }

        if !cleared {
            print("[PomodoroMusicCoordinator] Queue not cleared — track added wherever YTMD put it")
        }

        // Step C: skip to our track
        try? await Task.sleep(for: .milliseconds(300))
        let skipped = await sendCommand("/next")
        print("[PomodoroMusicCoordinator] Queue strategy /next: \(skipped ? "dispatched" : "failed")")

        return skipped
    }

    /// Attempt to DELETE /api/v1/queue (clears user-queued tracks).
    /// Returns true if the server accepted the request.
    private func deleteQueue(token: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/v1/queue") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            print("[PomodoroMusicCoordinator] DELETE /queue: no response")
            return false
        }

        if (200..<300).contains(http.statusCode) {
            print("[PomodoroMusicCoordinator] DELETE /queue: cleared (HTTP \(http.statusCode))")
            return true
        } else {
            print("[PomodoroMusicCoordinator] DELETE /queue: HTTP \(http.statusCode) — not supported by this YTMD version")
            return false
        }
    }

    // MARK: - URL Helpers

    /// Remove the `si` share-tracking query parameter that YouTube Music share links append.
    private func stripShareParam(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = components.queryItems?.filter { $0.name != "si" }
        return components.url ?? url
    }

    /// Build the POST /api/v1/queue payload from a YouTube Music URL.
    ///
    /// Supported shapes:
    ///   watch?v=VIDEO_ID           → { videoId }
    ///   watch?v=VIDEO_ID&list=PL   → { videoId, playlistId }
    ///
    /// Playlist-only URLs (playlist?list=PL) are intentionally rejected here —
    /// they don't carry a video ID that YTMD can queue, so they would never play.
    /// The settings UI guides the user to supply a watch?v= link instead.
    private func queuePayload(for url: URL) -> [String: Any]? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = url.host, host.contains("music.youtube.com")
        else { return nil }

        let items = components.queryItems ?? []

        // watch?v=VIDEO_ID[&list=PLAYLIST_ID]
        if url.path.contains("/watch"),
           let videoId = items.first(where: { $0.name == "v" })?.value {
            var payload: [String: Any] = ["videoId": videoId]
            if let listId = items.first(where: { $0.name == "list" })?.value {
                payload["playlistId"] = listId
            }
            return payload
        }

        // Playlist-only URL — not actionable
        if url.path.contains("/playlist") {
            print("[PomodoroMusicCoordinator] Playlist-only URL supplied for queue navigation.")
            print("[PomodoroMusicCoordinator] YTMD queue requires a video ID. Set a watch?v= link instead:")
            if let listId = items.first(where: { $0.name == "list" })?.value {
                print("[PomodoroMusicCoordinator]   watch?v=ANY_TRACK_FROM_THAT_PLAYLIST&list=\(listId)")
            }
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

    private func logQueueState(token: String) async {
        guard let url = URL(string: "\(baseURL)/api/v1/queue") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return }

        let raw = String(data: data, encoding: .utf8) ?? "(empty)"
        let preview = raw.count > 300 ? String(raw.prefix(300)) + "…" : raw
        print("[PomodoroMusicCoordinator] GET /api/v1/queue → HTTP \(http.statusCode): \(preview)")
    }

    // MARK: - YTMD HTTP Commands

    private func getToken() async -> String? {
        if let token = cachedToken { return token }

        guard let url = URL(string: "\(baseURL)/auth/boringNotch") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        guard let (data, _) = try? await session.data(for: request),
              let response = try? JSONDecoder().decode(AuthResponse.self, from: data)
        else {
            print("[PomodoroMusicCoordinator] Auth failed")
            return nil
        }

        cachedToken = response.accessToken
        return response.accessToken
    }

    @discardableResult
    private func sendCommand(_ endpoint: String, method: String = "POST") async -> Bool {
        guard let token = await getToken() else { return false }
        guard let url = URL(string: "\(baseURL)/api/v1\(endpoint)") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
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

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
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
