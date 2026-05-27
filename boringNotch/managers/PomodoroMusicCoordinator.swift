//
//  PomodoroMusicCoordinator.swift
//  boringNotch
//

import AppKit
import Defaults
import Foundation

/// Coordinates YouTube Music playback with Pomodoro timer phases.
///
/// Operates independently of the app-wide MusicManager/activeController so that
/// Pomodoro phase transitions always target YTMD directly via its companion HTTP API,
/// regardless of which music source the user has selected globally.
final class PomodoroMusicCoordinator {

    // MARK: - YTMD companion API config
    private let baseURL    = YouTubeMusicConfiguration.default.baseURL
    private let bundleID   = YouTubeMusicConfiguration.default.bundleIdentifier
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

    func timerPaused() {
        guard Defaults[.pomodoroYTMEnabled] else { return }
        pendingTask?.cancel()
        Task { await sendCommand("/pause") }
    }

    /// Called when the timer resumes mid-phase (no phase change occurred).
    /// Issues a simple play command — no URL navigation, no shuffle sync.
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

        // Navigate to the phase URL if one is configured
        if !urlString.isEmpty, let url = URL(string: urlString) {
            let navigated = await navigateViaAPI(to: url)
            if !navigated {
                // Fallback A: attempt to open the URL targeting the YTMD app directly.
                // YTMD (Electron) may not handle URL-document arguments, but we try.
                let opened = await openURLInYTMD(url)
                if !opened {
                    // Fallback B: open in the system default browser/handler as a last resort.
                    await MainActor.run { NSWorkspace.shared.open(url) }
                    print("[PomodoroMusicCoordinator] Navigation plugin unavailable — opened URL in default browser as fallback")
                }
            }
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

    // MARK: - Direct YTMD HTTP Commands

    /// Authenticate against the YTMD companion API and cache the token.
    private func getToken(retry: Bool = true) async -> String? {
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

    /// Send a playback command (play, pause, shuffle, etc.) to the YTMD companion API.
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

        if http.statusCode == 401 {
            cachedToken = nil
            return false
        }

        guard (200..<300).contains(http.statusCode) else {
            print("[PomodoroMusicCoordinator] Command \(endpoint) returned HTTP \(http.statusCode)")
            return false
        }

        return true
    }

    /// Navigate YTMD to a specific YouTube Music URL via the Navigation plugin API.
    /// Returns `true` on success, `false` if the plugin is not available or the call fails.
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
            print("[PomodoroMusicCoordinator] Navigation API unreachable")
            return false
        }

        if http.statusCode == 401 { cachedToken = nil }

        guard (200..<300).contains(http.statusCode) else {
            print("[PomodoroMusicCoordinator] Navigation API returned HTTP \(http.statusCode) — Navigation plugin may not be enabled")
            return false
        }

        return true
    }

    /// Fetch the current shuffle state from YTMD.
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

    // MARK: - App-level Helpers

    private func isYTMDRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Attempt to open the URL in the YTMD app via NSWorkspace.
    /// YTMD (Electron) may not handle URL arguments as documents, but this is the
    /// standard macOS fallback path. Returns true if the open call was dispatched.
    @discardableResult
    @MainActor
    private func openURLInYTMD(_ url: URL) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            print("[PomodoroMusicCoordinator] YTMD app not found for URL fallback")
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
            if let error {
                print("[PomodoroMusicCoordinator] NSWorkspace URL open failed: \(error.localizedDescription)")
            }
        }
        return true
    }
}

