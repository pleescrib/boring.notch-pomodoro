//
//  PomodoroMusicCoordinator.swift
//  boringNotch
//

import AppKit
import Defaults
import Foundation

/// Coordinates YouTube Music playback with Pomodoro timer phases.
/// When the integration is enabled, navigates YTMD to the configured URL
/// for each phase and ensures playback is running.
final class PomodoroMusicCoordinator {
    private let ytmdBundleID = "com.github.th-ch.youtube-music"
    private var pendingNavigationTask: Task<Void, Never>?

    // MARK: - Phase Events

    func phaseStarted(_ phase: PomodoroPhase) {
        guard Defaults[.pomodoroYTMEnabled] else { return }

        let urlString: String
        let shuffle: Bool

        switch phase {
        case .work:
            urlString = Defaults[.pomodoroYTMWorkURL]
            shuffle = Defaults[.pomodoroYTMWorkShuffle]
        case .shortBreak:
            urlString = Defaults[.pomodoroYTMBreakURL]
            shuffle = Defaults[.pomodoroYTMBreakShuffle]
        case .longBreak:
            urlString = Defaults[.pomodoroYTMLongBreakURL]
            shuffle = Defaults[.pomodoroYTMLongBreakShuffle]
        }

        // Cancel any in-flight navigation from a prior phase transition
        pendingNavigationTask?.cancel()

        if !urlString.isEmpty, let url = URL(string: urlString) {
            navigateAndPlay(url: url, shuffle: shuffle)
        } else {
            // No URL configured for this phase — just ensure playback continues
            MusicManager.shared.play()
        }
    }

    func timerPaused() {
        guard Defaults[.pomodoroYTMEnabled] else { return }
        pendingNavigationTask?.cancel()
        MusicManager.shared.pause()
    }

    // MARK: - Private

    private func navigateAndPlay(url: URL, shuffle: Bool) {
        // Open the URL inside YouTube Music Desktop App
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ytmdBundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, _ in }
        } else {
            // YTMD not installed; open in default browser as fallback
            NSWorkspace.shared.open(url)
        }

        // Give YTMD time to navigate before issuing playback commands
        pendingNavigationTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }

            MusicManager.shared.play()

            // Sync shuffle if needed
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            let currentShuffle = MusicManager.shared.isShuffled
            if currentShuffle != shuffle {
                MusicManager.shared.toggleShuffle()
            }
        }
    }
}
