//
//  PomodoroManager.swift
//  boringNotch
//

import Combine
import Defaults
import SwiftUI

// MARK: - Enums

enum PomodoroPhase: String, Defaults.Serializable {
    case work = "Work"
    case shortBreak = "Short Break"
    case longBreak = "Long Break"

    var displayName: String { rawValue }

    var systemImage: String {
        switch self {
        case .work: return "brain.head.profile"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak: return "figure.walk"
        }
    }
}

enum PomodoroPreset: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard = "25 / 5"
    case extended = "50 / 10"
    case custom = "Custom"

    var id: String { rawValue }
}

// MARK: - Manager

@MainActor
final class PomodoroManager: ObservableObject {
    static let shared = PomodoroManager()

    // MARK: Published state
    @Published var phase: PomodoroPhase = .work
    @Published var secondsRemaining: Int = 0
    @Published var isRunning: Bool = false
    @Published var phaseElapsedSeconds: Int = 0
    @Published private(set) var cycleCount: Int = 0
    @Published private(set) var sessionElapsedSeconds: Int = 0

    // MARK: Derived
    var progress: CGFloat {
        let total = CGFloat(totalSecondsForCurrentPhase())
        guard total > 0 else { return 0 }
        return CGFloat(secondsRemaining) / total
    }

    var formattedRemaining: String { formatSeconds(secondsRemaining) }
    var formattedPhaseElapsed: String { formatSeconds(phaseElapsedSeconds) }
    var formattedSessionElapsed: String { formatSeconds(sessionElapsedSeconds) }

    // MARK: Private
    private var timerCancellable: AnyCancellable?
    private var settingsCancellables = Set<AnyCancellable>()
    private let musicCoordinator = PomodoroMusicCoordinator()

    // MARK: Init
    private init() {
        cycleCount = Defaults[.pomodoroCycleCount]
        sessionElapsedSeconds = Defaults[.pomodoroSessionElapsed]
        secondsRemaining = totalSecondsForCurrentPhase()
        observeDurationDefaults()
    }

    // MARK: - Private: Defaults observers

    private func observeDurationDefaults() {
        // Refresh remaining time whenever a duration-affecting default changes
        // and the timer is not currently running.
        let refresh: () -> Void = { [weak self] in
            guard let self, !self.isRunning else { return }
            self.secondsRemaining = self.totalSecondsForCurrentPhase()
            self.phaseElapsedSeconds = 0
        }

        Defaults.publisher(.pomodoroPreset)
            .receive(on: RunLoop.main)
            .sink { _ in refresh() }
            .store(in: &settingsCancellables)

        Defaults.publisher(.pomodoroWorkDuration)
            .receive(on: RunLoop.main)
            .sink { _ in refresh() }
            .store(in: &settingsCancellables)

        Defaults.publisher(.pomodoroShortBreakDuration)
            .receive(on: RunLoop.main)
            .sink { _ in refresh() }
            .store(in: &settingsCancellables)

        Defaults.publisher(.pomodoroLongBreakDuration)
            .receive(on: RunLoop.main)
            .sink { _ in refresh() }
            .store(in: &settingsCancellables)
    }

    // MARK: - Public API

    /// True when the timer was paused mid-phase (as opposed to never started or between phases).
    private var isPausedMidPhase = false

    func startOrResume() {
        guard !isRunning else { return }
        isRunning = true
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
        if isPausedMidPhase {
            // Resuming within the same phase — just continue playback, no URL navigation
            musicCoordinator.timerResumed()
        } else {
            // Starting a new phase for the first time — full transition with URL navigation
            musicCoordinator.phaseStarted(phase)
        }
        isPausedMidPhase = false
    }

    func pause() {
        guard isRunning else { return }
        isRunning = false
        isPausedMidPhase = true
        timerCancellable?.cancel()
        timerCancellable = nil
        musicCoordinator.timerPaused()
    }

    func togglePlayPause() {
        if isRunning { pause() } else { startOrResume() }
    }

    func resetAll() {
        pause()
        phase = .work
        secondsRemaining = totalSecondsForCurrentPhase()
        phaseElapsedSeconds = 0
        cycleCount = 0
        sessionElapsedSeconds = 0
        persistState()
    }

    func resetCycleCount() {
        cycleCount = 0
        Defaults[.pomodoroCycleCount] = 0
    }

    func skipToNextPhase() {
        advancePhase()
    }

    // MARK: - Private

    private func tick() {
        if secondsRemaining > 0 {
            secondsRemaining -= 1
            phaseElapsedSeconds += 1
            sessionElapsedSeconds += 1
            persistState()
        } else {
            advancePhase()
        }
    }

    private func advancePhase() {
        if phase == .work {
            cycleCount += 1
            let longEnabled = Defaults[.pomodoroLongBreakEnabled]
            let cyclesNeeded = Defaults[.pomodoroCyclesBeforeLongBreak]
            phase = (longEnabled && cycleCount > 0 && cycleCount % cyclesNeeded == 0)
                ? .longBreak
                : .shortBreak
        } else {
            phase = .work
        }

        secondsRemaining = totalSecondsForCurrentPhase()
        phaseElapsedSeconds = 0
        isPausedMidPhase = false
        persistState()

        if isRunning {
            musicCoordinator.phaseStarted(phase)
        }
    }

    func totalSecondsForCurrentPhase() -> Int {
        switch phase {
        case .work:
            return Defaults[.pomodoroWorkDuration] * 60
        case .shortBreak:
            return Defaults[.pomodoroShortBreakDuration] * 60
        case .longBreak:
            return Defaults[.pomodoroLongBreakDuration] * 60
        }
    }

    private func persistState() {
        Defaults[.pomodoroCycleCount] = cycleCount
        Defaults[.pomodoroSessionElapsed] = sessionElapsedSeconds
    }

    private func formatSeconds(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
