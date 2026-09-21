import Foundation
import AVFoundation
import AudioToolbox
import UIKit
import os

/// Plays the alarm sound and haptics for as long as an alarm is unsilenced.
///
/// The audio session is configured `.playback`, which is what lets the
/// sound come through with the ringer switch set to silent — the single
/// most important detail in the whole feature, since a "silent" phone is
/// exactly the state most people sleep in. Combined with the `audio`
/// background mode in `project.yml`, it also keeps playing if the user
/// backgrounds the app mid-challenge rather than handing them a trivial
/// bypass.
@MainActor
final class AlarmAudioService {
    private var player: AVAudioPlayer?
    private var fallbackTimer: Timer?
    private var hapticTimer: Timer?
    private let logger = Logger(subsystem: "com.securechat", category: "alarmAudio")

    /// Bundled sound, in preference order. Add one of these to the target
    /// (a looping tone of a few seconds is ideal — the player loops it).
    ///
    /// `.caf` first because it's the format iOS decodes most cheaply, which
    /// matters for something that may loop for half an hour.
    private static let candidateSounds = [
        ("alarm", "caf"),
        ("alarm", "wav"),
        ("alarm", "mp3"),
    ]

    private(set) var isPlaying = false

    func start() {
        guard !isPlaying else { return }
        isPlaying = true

        configureSession()

        if let player = makePlayer() {
            self.player = player
            player.numberOfLoops = -1
            player.volume = 1.0
            player.play()
        } else {
            // No bundled asset: fall back to a repeating system alert tone.
            // Less pleasant, but a silent alarm is a broken alarm, and
            // shipping without the asset shouldn't fail silently.
            logger.error("No bundled alarm sound found; falling back to the system alert tone")
            startFallbackTone()
        }

        startHaptics()
    }

    func stop() {
        isPlaying = false
        player?.stop()
        player = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        hapticTimer?.invalidate()
        hapticTimer = nil
        // Deactivating with `.notifyOthersOnDeactivation` lets whatever was
        // playing before (music, a podcast) resume on its own, instead of
        // leaving the user with silence after the alarm stops.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // `.duckOthers` rather than interrupting outright: if something
            // else is playing, quieting it is enough to be heard over.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            logger.error("Couldn't configure the audio session for the alarm")
        }
    }

    private func makePlayer() -> AVAudioPlayer? {
        for (name, ext) in Self.candidateSounds {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { continue }
            if let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                return player
            }
        }
        return nil
    }

    private func startFallbackTone() {
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            AudioServicesPlayAlertSound(SystemSoundID(1005))
        }
        AudioServicesPlayAlertSound(SystemSoundID(1005))
    }

    /// Haptics alongside the sound. Genuinely useful rather than decorative:
    /// it's what gets through when the phone is face-down on a mattress,
    /// or when the user sleeps with earplugs in.
    private func startHaptics() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        hapticTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                generator.notificationOccurred(.warning)
            }
        }
    }
}
