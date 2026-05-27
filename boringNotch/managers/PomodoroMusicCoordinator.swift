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
/// Navigation strategy (tried in order, fails silently at each step):
///   1. POST /api/v1/navigate  — companion API (requires Navigation plugin)
///   2. AppleScript `open location` — works with many Electron apps on macOS
///   3. Continue with play/shuffle only — no error dialogs, music keeps going
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
        if !urlString.isEmpty, let url = URL(string: urlString) {
            let navigated = await navigateViaAPI(to: url)
            if !navigated {
                await navigateViaAppleScript(urlString: urlString)
            }
            // Give YTMD time to load the new content
            try? await Task.sleep(for: .seconds(2))
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

    // MARK: - Navigation

    /// Try the companion API /navigate endpoint (requires YTMD Navigation plugin to expose it).
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
        else {
            print("[PomodoroMusicCoordinator] API navigate: no response")
            return false
        }

        if http.statusCode == 401 { cachedToken = nil }

        guard (200..<300).contains(http.statusCode) else {
            print("[PomodoroMusicCoordinator] API navigate: HTTP \(http.statusCode) — trying AppleScript fallback")
            return false
        }

        print("[PomodoroMusicCoordinator] API navigate: success")
        return true
    }

    /// Try AppleScript `open location` — works with Electron apps that handle URL events.
    private func navigateViaAppleScript(urlString: String) async {
        let escaped = urlString.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "YouTube Music"
            open location "\(escaped)"
        end tell
        """
        do {
            try await AppleScriptHelper.executeVoid(script)
            print("[PomodoroMusicCoordinator] AppleScript navigate: success")
        } catch {
            print("[PomodoroMusicCoordinator] AppleScript navigate: \(error.localizedDescription) — playing current content")
        }
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
