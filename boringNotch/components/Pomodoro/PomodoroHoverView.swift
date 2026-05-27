//
//  PomodoroHoverView.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct PomodoroHoverView: View {
    @ObservedObject var pomodoroManager = PomodoroManager.shared

    var body: some View {
        VStack(spacing: 12) {
            phaseLabel
            countdown
            statsRow
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Subviews

    private var phaseLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: pomodoroManager.phase.systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(pomodoroManager.phase.displayName.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.5)
        }
        .foregroundStyle(Color.effectiveAccent)
    }

    private var countdown: some View {
        Text(pomodoroManager.formattedRemaining)
            .font(.system(size: 46, weight: .thin, design: .monospaced))
            .foregroundStyle(.white)
            .contentTransition(.numericText(countsDown: true))
            .animation(.smooth(duration: 0.3), value: pomodoroManager.secondsRemaining)
    }

    private var statsRow: some View {
        HStack(spacing: 20) {
            statItem(
                label: "Elapsed",
                value: pomodoroManager.formattedPhaseElapsed
            )
            Divider()
                .frame(height: 24)
                .opacity(0.3)
            statItem(
                label: "Session",
                value: pomodoroManager.formattedSessionElapsed
            )
            Divider()
                .frame(height: 24)
                .opacity(0.3)
            statItem(
                label: "Cycles",
                value: "\(pomodoroManager.cycleCount)"
            )
        }
        .foregroundStyle(.secondary)
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.3), value: value)
            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var controls: some View {
        HStack(spacing: 24) {
            // Reset button
            Button {
                withAnimation(.smooth) {
                    pomodoroManager.resetAll()
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .help("Reset timer")

            // Play / Pause (primary action)
            Button {
                withAnimation(.smooth) {
                    pomodoroManager.togglePlayPause()
                }
            } label: {
                Image(systemName: pomodoroManager.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(Color.effectiveAccent)
                    .clipShape(Circle())
                    .shadow(color: Color.effectiveAccent.opacity(0.5), radius: 8)
            }
            .buttonStyle(PlainButtonStyle())
            .help(pomodoroManager.isRunning ? "Pause" : "Start")

            // Skip to next phase
            Button {
                withAnimation(.smooth) {
                    pomodoroManager.skipToNextPhase()
                }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .help("Skip to next phase")
        }
    }
}
