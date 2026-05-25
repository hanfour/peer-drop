import Foundation

/// Cross-platform audio session category. iOS maps each case to a
/// (AVAudioSession.Category, Mode, [CategoryOptions]) triple; macOS
/// has no session category concept so each case is effectively a no-op
/// (system routes audio automatically).
///
/// Only the 3 combinations actually used in PeerDrop/Voice/ are
/// exposed. Add a 4th case if a new combination is needed.
public enum AudioSessionCategory {
    /// AVAudioSession: .playAndRecord + .voiceChat
    /// Used by CallKitManager + during active voice call.
    case voiceChat

    /// AVAudioSession: .playback + .default
    /// Used by VoicePlayer (ringtone playback, voice-note playback).
    case playback

    /// AVAudioSession: .playAndRecord + .default + .defaultToSpeaker
    /// Used by VoiceRecorder (voice-note capture with speaker monitor).
    case playAndRecordSpeaker
}

/// Cross-platform audio session abstraction. iOS implementation wraps
/// AVAudioSession.sharedInstance(). macOS no-op (the system handles
/// voice-chat audio routing automatically).
public protocol AudioSessionConfiguring: AnyObject {
    /// Configure the session for the given semantic category and activate it.
    /// iOS: calls setCategory + setActive(true). macOS: no-op.
    /// Throws on iOS if the category is incompatible with the current device state.
    func activate(_ category: AudioSessionCategory) throws

    /// Deactivate the session. iOS: calls setActive(false, options: .notifyOthersOnDeactivation).
    /// macOS: no-op.
    func deactivate() throws

    /// Override output to speaker (iOS only; macOS no-op since user picks
    /// output device via system menu).
    func overrideOutputToSpeaker(_ speaker: Bool) throws

    /// Synchronous read of current microphone permission status.
    /// iOS: AVAudioSession.recordPermission == .granted.
    /// macOS: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized.
    var recordPermissionGranted: Bool { get }

    /// Async request for microphone permission.
    /// iOS: wraps AVAudioSession.requestRecordPermission.
    /// macOS: wraps AVCaptureDevice.requestAccess(for: .audio).
    func requestRecordPermission() async -> Bool
}
