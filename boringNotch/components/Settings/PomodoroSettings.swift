//
//  PomodoroSettings.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct PomodoroSettings: View {
    @Default(.pomodoroPreset) var preset
    @Default(.pomodoroWorkDuration) var workDuration
    @Default(.pomodoroShortBreakDuration) var shortBreakDuration
    @Default(.pomodoroLongBreakDuration) var longBreakDuration
    @Default(.pomodoroLongBreakEnabled) var longBreakEnabled
    @Default(.pomodoroCyclesBeforeLongBreak) var cyclesBeforeLongBreak
    @Default(.pomodoroCustomWorkDuration) var customWorkDuration
    @Default(.pomodoroCustomBreakDuration) var customBreakDuration

    @Default(.pomodoroYTMEnabled) var ytmEnabled
    @Default(.pomodoroYTMWorkURL) var ytmWorkURL
    @Default(.pomodoroYTMBreakURL) var ytmBreakURL
    @Default(.pomodoroYTMLongBreakURL) var ytmLongBreakURL
    @Default(.pomodoroYTMWorkShuffle) var ytmWorkShuffle
    @Default(.pomodoroYTMBreakShuffle) var ytmBreakShuffle
    @Default(.pomodoroYTMLongBreakShuffle) var ytmLongBreakShuffle

    @ObservedObject var pomodoroManager = PomodoroManager.shared

    var body: some View {
        Form {
            presetSection
            longBreakSection
            sessionSection
            ytmSection
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Pomodoro")
    }

    // MARK: - Sections

    private var presetSection: some View {
        Section {
            Picker("Preset", selection: $preset) {
                ForEach(PomodoroPreset.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .onChange(of: preset) { _, newPreset in
                applyPreset(newPreset)
            }

            if preset == .custom {
                Stepper(value: $customWorkDuration, in: 1...120) {
                    HStack {
                        Text("Work duration")
                        Spacer()
                        Text("\(customWorkDuration) min").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: customWorkDuration) { _, v in
                    workDuration = v
                }

                Stepper(value: $customBreakDuration, in: 1...60) {
                    HStack {
                        Text("Break duration")
                        Spacer()
                        Text("\(customBreakDuration) min").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: customBreakDuration) { _, v in
                    shortBreakDuration = v
                }
            } else {
                HStack {
                    Text("Work")
                    Spacer()
                    Text("\(workDuration) min").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Short break")
                    Spacer()
                    Text("\(shortBreakDuration) min").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Timer preset")
        } footer: {
            Text("Changes take effect at the start of the next phase.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var longBreakSection: some View {
        Section {
            Toggle("Enable long break", isOn: $longBreakEnabled)
                .tint(.effectiveAccent)

            if longBreakEnabled {
                Stepper(value: $longBreakDuration, in: 1...120) {
                    HStack {
                        Text("Long break duration")
                        Spacer()
                        Text("\(longBreakDuration) min").foregroundStyle(.secondary)
                    }
                }

                Stepper(value: $cyclesBeforeLongBreak, in: 1...12) {
                    HStack {
                        Text("Cycles before long break")
                        Spacer()
                        Text("\(cyclesBeforeLongBreak)").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Long break")
        } footer: {
            if longBreakEnabled {
                Text("A long break is triggered after every \(cyclesBeforeLongBreak) completed work cycle\(cyclesBeforeLongBreak == 1 ? "" : "s").")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private var sessionSection: some View {
        Section {
            HStack {
                Text("Current cycles")
                Spacer()
                Text("\(pomodoroManager.cycleCount)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Session elapsed")
                Spacer()
                Text(pomodoroManager.formattedSessionElapsed).foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
            Button(role: .destructive) {
                withAnimation(.smooth) {
                    pomodoroManager.resetCycleCount()
                }
            } label: {
                Text("Reset cycle count")
            }
        } header: {
            Text("Session")
        }
    }

    private var ytmSection: some View {
        Section {
            Toggle("Enable music integration", isOn: $ytmEnabled)
                .tint(.effectiveAccent)

            if ytmEnabled {
                urlRow(
                    label: "Work track or playlist URL",
                    text: $ytmWorkURL,
                    shuffle: $ytmWorkShuffle
                )
                urlRow(
                    label: "Short break URL",
                    text: $ytmBreakURL,
                    shuffle: $ytmBreakShuffle
                )
                urlRow(
                    label: "Long break URL",
                    text: $ytmLongBreakURL,
                    shuffle: $ytmLongBreakShuffle
                )
            }
        } header: {
            Text("YouTube Music")
        } footer: {
            if ytmEnabled {
                Text("Paste a YouTube Music track or playlist URL for each phase. Leave blank to keep whatever is already playing. Requires the YouTube Music Desktop App.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func urlRow(label: String, text: Binding<String>, shuffle: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("https://music.youtube.com/...", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Toggle("Shuffle", isOn: shuffle)
                .tint(.effectiveAccent)
                .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Preset Application

    private func applyPreset(_ preset: PomodoroPreset) {
        switch preset {
        case .standard:
            workDuration = 25
            shortBreakDuration = 5
        case .extended:
            workDuration = 50
            shortBreakDuration = 10
        case .custom:
            workDuration = customWorkDuration
            shortBreakDuration = customBreakDuration
        }
    }
}
