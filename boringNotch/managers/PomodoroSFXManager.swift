//
//  PomodoroSFXManager.swift
//  boringNotch
//

import AVFoundation
import Defaults
import Foundation

/// Plays the three Pomodoro sound effects:
///   - Gong         → fires when a work session begins (after any break)
///   - Bright chimes → fires 15 s before the current work session ends
///   - Down chimes  → fires 15 s before a break ends (i.e., before work resumes)
@MainActor
final class PomodoroSFXManager {
    static let shared = PomodoroSFXManager()

    private var gongPlayer: AVAudioPlayer?
    private var brightChimesPlayer: AVAudioPlayer?
    private var downChimesPlayer: AVAudioPlayer?

    private init() {
        loadSounds()
    }

    // MARK: - Playback

    func playWorkStart() {
        guard Defaults[.pomodoroSFXEnabled] else { return }
        play(gongPlayer)
    }

    func playPreBreak() {
        guard Defaults[.pomodoroSFXEnabled] else { return }
        play(brightChimesPlayer)
    }

    func playPreWork() {
        guard Defaults[.pomodoroSFXEnabled] else { return }
        play(downChimesPlayer)
    }

    // MARK: - Private

    private func play(_ player: AVAudioPlayer?) {
        guard let p = player else { return }
        p.volume = Float(Defaults[.pomodoroSFXVolume])
        if p.isPlaying { p.stop(); p.currentTime = 0 }
        p.play()
    }

    private func loadSounds() {
        gongPlayer        = makePlayer(filename: "pomodoro_gong")
        brightChimesPlayer = makePlayer(filename: "pomodoro_chime_bright")
        downChimesPlayer  = makePlayer(filename: "pomodoro_chime_down")
    }

    private func makePlayer(filename: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: filename, withExtension: "mp3") else {
            print("[PomodoroSFXManager] ⚠️ Missing sound file: \(filename).mp3")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return player
        } catch {
            print("[PomodoroSFXManager] ⚠️ Failed to load \(filename).mp3: \(error)")
            return nil
        }
    }
}
