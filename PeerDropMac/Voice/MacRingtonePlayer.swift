#if canImport(AppKit)
import AVFoundation
import AppKit
import os

/// Plays the bundled incoming-call ringtone with looping + fade-out stop.
///
/// **Asset source:**
///   - Preferred: `PeerDropMac/Resources/Ringtone.caf` bundled into the
///     `.app` (loopable, mono, 44.1 kHz, ~5s).
///   - Fallback: `NSSound(named: "Glass")` re-triggered every ~3s.
///     Used when `Ringtone.caf` is missing from the bundle (early dev
///     builds before the audio asset has been commissioned). The
///     fallback keeps voice-call code paths exercisable while the
///     production asset is in flight. Sandboxed apps may have
///     `NSSound(named:)` return nil for system sounds in some
///     configurations; the ringtone is then visually-only until
///     Ringtone.caf is added.
///
/// **DND mode:** `start(silent: true)` keeps the timer + panel semantics
/// uniform (the player still "plays" so cleanup paths are symmetric)
/// but at zero volume. The decision to silence comes from
/// `DNDFilter.shouldSilenceRingtone()`; the wiring lives in
/// `MacCallProvider.reportIncomingCall`.
@MainActor
final class MacRingtonePlayer {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "Ringtone")
    private var player: AVAudioPlayer?
    private var fallbackTask: Task<Void, Never>?
    private var fallbackSilent: Bool = false

    init() {
        if let url = Bundle.main.url(forResource: "Ringtone", withExtension: "caf") {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.prepareToPlay()
                self.player = player
                logger.info("Loaded bundled Ringtone.caf")
            } catch {
                logger.error("AVAudioPlayer init failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.warning("Ringtone.caf not bundled — falling back to NSSound(\"Glass\") loop")
        }
    }

    func start(silent: Bool = false) {
        stop(fadeOut: 0)

        if let player {
            player.volume = silent ? 0 : 1
            player.currentTime = 0
            player.play()
            return
        }

        // Fallback path: re-trigger NSSound every 3s. Volume is
        // controlled by setting `volume` on the NSSound at play time.
        fallbackSilent = silent
        fallbackTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if !self.fallbackSilent, let sound = NSSound(named: NSSound.Name("Glass")) {
                    sound.volume = 1
                    sound.play()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop(fadeOut: TimeInterval = 0.2) {
        fallbackTask?.cancel()
        fallbackTask = nil

        guard let player, player.isPlaying else { return }
        if fadeOut > 0 {
            player.setVolume(0, fadeDuration: fadeOut)
            Task { @MainActor [weak player] in
                try? await Task.sleep(for: .seconds(fadeOut))
                player?.stop()
            }
        } else {
            player.stop()
        }
    }
}
#endif
