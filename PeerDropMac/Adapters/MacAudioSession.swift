#if canImport(AppKit)
import AVFoundation
import PeerDropPlatform

/// macOS adapter for `AudioSessionConfiguring`.
///
/// On macOS there is no AVAudioSession category concept; the system
/// routes voice-chat audio automatically. `activate`, `deactivate`, and
/// `overrideOutputToSpeaker` are no-ops (matches the protocol's
/// documented macOS semantics).
///
/// `recordPermissionGranted` / `requestRecordPermission` wrap
/// `AVCaptureDevice.audio` so the user receives the same
/// "PeerDrop wants microphone access" prompt the iOS adapter triggers.
/// This is what differentiates the Mac adapter from the bundled
/// `NoOpAudioSession` (which always returns `false`).
final class MacAudioSession: AudioSessionConfiguring {
    func activate(_ category: AudioSessionCategory) throws {
        // No-op: WebRTC self-manages voice-chat routing on macOS.
    }

    func deactivate() throws {
        // No-op (see activate).
    }

    func overrideOutputToSpeaker(_ speaker: Bool) throws {
        // No-op: user picks output device via the system Volume menu.
    }

    var recordPermissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
#endif
