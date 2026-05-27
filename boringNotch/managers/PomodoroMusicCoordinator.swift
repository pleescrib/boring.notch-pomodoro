//
//  PomodoroMusicCoordinator.swift
//  boringNotch
//

import AppKit
import Defaults
import Foundation

/// Coordinates YouTube Music playback with Pomodoro timer phases.
///
/// Targets YTMD directly via its companion HTTP API so Pomodoro transitions
/// work regardless of the app-wide music controller preference.
///
/// Navigation strategy (tried in order, no dialogs on failure):
///   1. POST /api/v1/navigate  — companion API (requires Navigation plugin route; 404 in most builds)
///   2. ytmd:// custom URL scheme — YTMD's Electron open-url handler (not registered on this machine)
///   3. POST /api/v1/queue — inject videoId or playlistId extracted from the configured URL
///   4. Silent continue — play/shuffle the current content with no error
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
    private var hasLoggedQueueFormat = false

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

    /// Called when the timer is paused mid-phase.
    func timerPaused() {
        guard Defaults[.pomodoroYTMEnabled] else { return }
        pendingTask?.cancel()
        Task { await sendCommand("/pause") }
    }

    /// Called when the timer resumes mid-phase (no phase change).
    /// Issues only a play command — no URL navigation, no shuffle sync.
    func timerResumed() {
        guard Defaults[.pomodoroYTMEnabled] else { return }
        Task { await sendCommand("/play") }
    }

    // MARK: - Phase Transition

    private func executePhaseTransition(urlString: String, shuffle: Bool) async {
        guard !Task.isCancelled else { return }

        guard isYTMDRunning() else {
            print("[PomodoroMusicCoordinator] YTMD not running — skipping phase transition")
            return
        }

        // Pause current playback before switching content
        await sendCommand("/pause")
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        // Navigate to the configured URL (best-effort, silent on failure)
        var navigated = false
        if !urlString.isEmpty, let url = URL(string: urlString) {
            // Strategy 1: companion API /navigate endpoint
            navigated = await navigateViaAPI(to: url)

            // Strategy 2: ytmd:// custom URL scheme (requires YTMD to register scheme)
            if !navigated {
                navigated = await navigateViaYTMDScheme(urlString: urlString)
            }

            // Strategy 3: queue API — extract videoId / playlistId and inject via /api/v1/queue
            if !navigated {
                navigated = await navigateViaQueue(url: url)
            }

            if navigated {
                // Give YTMD time to load the new content before resuming playback
                try? await Task.sleep(for: .seconds(2))
            } else {
                print("[PomodoroMusicCoordinator] All navigation strategies exhausted — continuing with current content")
            }
            guard !Task.isCancelled else { return }
        }

        // Start playback for this phase
        await sendCommand("/play")

        // Sync shuffle state with the phase preference
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }

        if let currentShuffle = await getShuffleState(), currentShuffle != shuffle {
            await sendCommand("/shuffle")
        }
    }

    // MARK: - Navigation Strategies

    /// Strategy 1: POST /api/v1/navigate via YTMD companion API.
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

        guard (200..<300).contains(http.statusCode) else {
            print("[PomodoroMusicCoordinator] API navigate: HTTP \(http.statusCode)")
            return false
        }

        print("[PomodoroMusicCoordinator] API navigate: success")
        return true
    }

    /// Strategy 2: ytmd:// custom URL scheme dispatch.
    /// Only attempted when YTMD has registered the ytmd:// scheme (pre-checked via urlForApplication).
    @MainActor
    private func navigateViaYTMDScheme(urlString: String) async -> Bool {
        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let ytmdURL = URL(string: "ytmd://navigate?url=\(encoded)")
        else { return false }

        guard NSWorkspace.shared.urlForApplication(toOpen: ytmdURL) != nil else {
            return false
        }

        let opened = NSWorkspace.shared.open(ytmdURL)
        if opened {
            print("[PomodoroMusicCoordinator] ytmd:// scheme: dispatched")
        }
        return opened
    }

    /// Strategy 3: POST /api/v1/queue with a videoId or playlistId extracted from the URL.
    ///
    /// Supported URL shapes:
    ///   https://music.youtube.com/watch?v=VIDEO_ID   → { "videoId": "VIDEO_ID" }
    ///   https://music.youtube.com/playlist?list=ID   → { "playlistId": "ID" }
    ///
    /// The first call also logs the current GET /api/v1/queue response for diagnostics.
    private func navigateViaQueue(url: URL) async -> Bool {
        guard let payload = queuePayload(for: url) else {
            print("[PomodoroMusicCoordinator] Queue navigate: could not extract videoId/playlistId from URL")
            return false
        }

        guard let token = await getToken() else { return false }

        // Log current queue format once (helps diagnose the endpoint's response shape)
        if !hasLoggedQueueFormat {
            hasLoggedQueueFormat = true
            await logQueueState(token: token)
        }

        guard let endpoint = URL(string: "\(baseURL)/api/v1/queue") else { return false }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            print("[PomodoroMusicCoordinator] Queue navigate: no response")
            return false
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        print("[PomodoroMusicCoordinator] Queue POST payload: \(payload)")
        print("[PomodoroMusicCoordinator] Queue POST → HTTP \(http.statusCode), body: \(body)")

        if http.statusCode == 401 { cachedToken = nil }

        guard (200..<300).contains(http.statusCode) else { return false }

        print("[PomodoroMusicCoordinator] Queue navigate: success")
        return true
    }

    /// Extract the queue POST payload from a YouTube Music URL.
    /// Returns nil if the URL shape isn't recognised.
    private func queuePayload(for url: URL) -> [String: String]? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = url.host, host.contains("music.youtube.com")
        else { return nil }

        let items = components.queryItems ?? []

        // watch?v=VIDEO_ID  (optionally also &list=PLAYLIST_ID for a song in a playlist context)
        if url.path.contains("/watch"),
           let videoId = items.first(where: { $0.name == "v" })?.value {
            var payload: [String: String] = ["videoId": videoId]
            if let listId = items.first(where: { $0.name == "list" })?.value {
                payload["playlistId"] = listId
            }
            return payload
        }

        // playlist?list=PLAYLIST_ID
        if url.path.contains("/playlist"),
           let listId = items.first(where: { $0.name == "list" })?.value {
            return ["playlistId": listId]
        }

        return nil
    }

    /// Log the current GET /api/v1/queue response body for diagnostics.
    private func logQueueState(token: String) async {
        guard let url = URL(string: "\(baseURL)/api/v1/queue") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return }

        let body = String(data: data, encoding: .utf8) ?? "(no body)"
        print("[PomodoroMusicCoordinator] GET /api/v1/queue → HTTP \(http.statusCode)")
        print("[PomodoroMusicCoordinator] Queue body: \(body)")
    }

    // MARK: - Direct YTMD HTTP Commands

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
            print("[PomodoroMusicCoordinator] Command \(endpoint): HTTP \(http.statusCode)")
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

    // MARK: - App Helpers

    private func isYTMDRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}
