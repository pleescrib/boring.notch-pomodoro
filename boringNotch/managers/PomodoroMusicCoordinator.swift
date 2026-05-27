//
//  PomodoroMusicCoordinator.swift
//  boringNotch
//

import Defaults
import Foundation

/// Coordinates YouTube Music playback with Pomodoro timer phases.
/// Uses the YTMD companion HTTP API (Navigation plugin + playback controls)
/// to navigate to phase-configured playlists and manage play/shuffle state.
final class PomodoroMusicCoordinator {
    private var pendingTask: Task<Void, Never>?

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

        pendingTask?.cancel()
        pendingTask = Task {
            // Navigate YTMD to the configured URL via the companion API Navigation plugin
            if !urlString.isEmpty, let url = URL(string: urlString) {
                // Pause current playback cleanly before switching content
                MusicManager.shared.pause()
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }

                MusicManager.shared.navigate(to: url)
                // Give YTMD time to load the new content before issuing playback commands
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }

            // Start playback for this phase
            MusicManager.shared.play()

            // Sync shuffle state with the phase preference
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            let currentShuffle = MusicManager.shared.isShuffled
            if currentShuffle != shuffle {
                MusicManager.shared.toggleShuffle()
            }
        }
    }

    func timerPaused() {
        guard Defaults[.pomodoroYTMEnabled] else { return }
        pendingTask?.cancel()
        MusicManager.shared.pause()
    }
}
