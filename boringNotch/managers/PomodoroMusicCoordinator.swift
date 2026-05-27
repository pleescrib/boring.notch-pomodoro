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
///   1. POST /api/v1/navigate  — companion API (requires Navigation plugin to
///      register this route; returns 404 in most YTMD builds)
///   2. ytmd:// custom URL scheme — YTMD registers ytmd:// via
///      app.setAsDefaultProtocolClient; opening ytmd://navigate?url=<encoded>
///      triggers YTMD's open-url Electron handler. A scheme pre-check ensures
///      we never open this if YTMD hasn't registered it (avoids OS dialogs).
///   3. Silent continue — play/shuffle the current content with no error.
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
    private var hasLoggedAvailableRoutes = false

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

            // Strategy 2: ytmd:// custom URL scheme
            if !navigated {
                navigated = await navigateViaYTMDScheme(urlString: urlString)
            }

            if navigated {
                // Give YTMD time to load the new content before we resume playback
                try? await Task.sleep(for: .seconds(2))
            } else {
                // Log available routes once so the user can see what YTMD actually exposes
                if !hasLoggedAvailableRoutes {
                    hasLoggedAvailableRoutes = true
                    await probeAndLogAvailableRoutes()
                }
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
    /// Requires the Navigation plugin to register this route with the API Server.
    /// Returns true on HTTP 2xx, false otherwise (no dialogs on failure).
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
            print("[PomodoroMusicCoordinator] API navigate: HTTP \(http.statusCode) — trying ytmd:// scheme")
            return false
        }

        print("[PomodoroMusicCoordinator] API navigate: success")
        return true
    }

    /// Strategy 2: Open ytmd://navigate?url=<encoded> via macOS URL scheme dispatch.
    ///
    /// th-ch/youtube-music registers itself as the handler for the ytmd:// scheme
    /// via app.setAsDefaultProtocolClient('ytmd'). Opening a ytmd:// URL triggers
    /// YTMD's Electron open-url event handler, which can navigate the main window.
    ///
    /// A handler pre-check via NSWorkspace ensures we never trigger an OS "no
    /// application found" error dialog when the scheme isn't registered.
    @MainActor
    private func navigateViaYTMDScheme(urlString: String) async -> Bool {
        // Percent-encode the inner URL so it survives as a query parameter
        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let ytmdURL = URL(string: "ytmd://navigate?url=\(encoded)")
        else {
            print("[PomodoroMusicCoordinator] ytmd:// scheme: could not build URL")
            return false
        }

        // Pre-check: bail silently if no app is registered for ytmd://
        guard NSWorkspace.shared.urlForApplication(toOpen: ytmdURL) != nil else {
            print("[PomodoroMusicCoordinator] ytmd:// scheme: no handler registered — navigation not available")
            print("[PomodoroMusicCoordinator] Continuing with current YTMD content (play + shuffle only)")
            return false
        }

        let opened = NSWorkspace.shared.open(ytmdURL)
        if opened {
            print("[PomodoroMusicCoordinator] ytmd:// scheme: dispatched \(ytmdURL.absoluteString)")
        } else {
            print("[PomodoroMusicCoordinator] ytmd:// scheme: open returned false")
        }
        return opened
    }

    // MARK: - Diagnostic Route Probe

    /// Makes a single diagnostic GET to the API root to log what routes YTMD actually exposes.
    /// Called once when all navigation strategies have failed — helps with future debugging.
    private func probeAndLogAvailableRoutes() async {
        guard let token = await getToken() else { return }

        // Try a few candidate navigation-related endpoints so the user can see in console
        // what HTTP status each returns — useful for identifying the correct path.
        let candidates = [
            "/api/v1/navigate",
            "/api/v1/navigation",
            "/api/v1/queue",
            "/api/v1/song",
        ]

        print("[PomodoroMusicCoordinator] ── Navigation unavailable. Probing YTMD API endpoints ──")
        await withTaskGroup(of: Void.self) { group in
            for path in candidates {
                group.addTask {
                    guard let url = URL(string: "\(self.baseURL)\(path)") else { return }
                    var req = URLRequest(url: url)
                    req.httpMethod = "GET"
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    if let (_, resp) = try? await self.session.data(for: req),
                       let http = resp as? HTTPURLResponse {
                        print("[PomodoroMusicCoordinator]   \(path) → HTTP \(http.statusCode)")
                    }
                }
            }
        }
        print("[PomodoroMusicCoordinator] ─────────────────────────────────────────────────────")
        print("[PomodoroMusicCoordinator] Playback will use current YTMD content. To enable")
        print("[PomodoroMusicCoordinator] playlist switching, ensure the Navigation plugin in")
        print("[PomodoroMusicCoordinator] YTMD exposes /api/v1/navigate via the API Server plugin.")
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
