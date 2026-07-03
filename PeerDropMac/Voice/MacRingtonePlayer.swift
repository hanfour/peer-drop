#if canImport(AppKit)
import AVFoundation
import AppKit
import os

/// Plays the bundled incoming-call ringtone with looping + fade-out stop.
///
/// **Asset source:**
///   - Preferred: `PeerDropMac/Resources/Ringtone.caf` bundled into the
///     `.app` (loopable, mono, 44.1 kHz, 3.18 s; CC0 — provenance and
///     processing steps in `PeerDropMac/Resources/README.md`).
///   - Fallback: `NSSound(named: "Glass")` re-triggered every ~3s. Only
///     a last-resort safety net for builds that somehow strip the
///     resource — NOT a production path: sandboxed apps may have
///     `NSSound(named:)` return nil for system sounds in some
///     configurations, leaving the ringtone visually-only. A missing
///     `Ringtone.caf` is a ship blocker, not a degraded mode.
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
    private var fadeStopTask: Task<Void, Never>?
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
        fadeStopTask?.cancel()
        fadeStopTask = nil

        guard let player, player.isPlaying else { return }
        if fadeOut > 0 {
            player.setVolume(0, fadeDuration: fadeOut)
            // Must stay cancellable: start() calls stop(fadeOut: 0) first,
            // and a ring re-started inside the fade window would otherwise
            // be killed when this delayed stop fires.
            fadeStopTask = Task { @MainActor [weak player] in
                try? await Task.sleep(for: .seconds(fadeOut))
                guard !Task.isCancelled else { return }
                player?.stop()
            }
        } else {
            player.stop()
        }
    }
}
#endif
