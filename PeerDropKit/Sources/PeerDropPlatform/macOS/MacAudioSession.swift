#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import AVFoundation

/// macOS adapter for `AudioSessionConfiguring` (audit round 16).
///
/// The M1d Platform abstraction left macOS on `NoOpAudioSession`, whose
/// `requestRecordPermission` returns `false` — chat voice messages route
/// their mic-permission check through `audioSession()`, so recording was
/// permanently impossible on the Mac (the permission alert fired on every
/// attempt). macOS has no `AVAudioSession`; category activation and output
/// routing are no-ops here, and permission maps to `AVCaptureDevice`'s
/// audio authorization, which is what gates microphone capture on the Mac.
final class MacAudioSession: AudioSessionConfiguring {
    func activate(_ category: AudioSessionCategory) throws {
        // No AVAudioSession on macOS — AVAudioRecorder/Player work without
        // session activation; output routing is system-managed.
    }

    func deactivate() throws {}

    func overrideOutputToSpeaker(_ speaker: Bool) throws {
        // System-managed on macOS; no per-app speaker override.
    }

    var recordPermissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestRecordPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
#endif
