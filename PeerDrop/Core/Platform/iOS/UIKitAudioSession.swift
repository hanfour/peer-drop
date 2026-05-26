#if canImport(UIKit)
import Foundation
import AVFoundation

final class UIKitAudioSession: AudioSessionConfiguring {
    private let session = AVAudioSession.sharedInstance()

    func activate(_ category: AudioSessionCategory) throws {
        switch category {
        case .voiceChat:
            try session.setCategory(.playAndRecord, mode: .voiceChat)
        case .playback:
            try session.setCategory(.playback, mode: .default)
        case .playAndRecordSpeaker:
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        }
        try session.setActive(true)
    }

    func deactivate() throws {
        try session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func overrideOutputToSpeaker(_ speaker: Bool) throws {
        try session.overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    var recordPermissionGranted: Bool {
        session.recordPermission == .granted
    }

    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            session.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
#endif
