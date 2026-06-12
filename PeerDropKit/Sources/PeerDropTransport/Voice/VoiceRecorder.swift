import AVFoundation
import PeerDropPlatform

public enum VoiceRecorderError: Error, LocalizedError {
    /// AVAudioRecorder.record() returned false — capture never started
    /// (typically no input device, e.g. a Mac mini without a microphone).
    case captureFailedToStart

    public var errorDescription: String? {
        switch self {
        case .captureFailedToStart:
            return String(localized: "Could not start recording — no microphone available")
        }
    }
}

/// Records voice messages using AVAudioRecorder.
@MainActor
public final class VoiceRecorder: NSObject, ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var audioLevel: Float = 0

    private let audioSession: AudioSessionConfiguring

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var durationTimer: Timer?
    private var levelTimer: Timer?

    public init(audioSession: AudioSessionConfiguring = PlatformDependencies.shared.audioSession()) {
        self.audioSession = audioSession
        super.init()
    }

    /// Start recording a voice message.
    public func startRecording() throws {
        try audioSession.activate(.playAndRecordSpeaker)

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "VoiceRecording_\(UUID().uuidString).m4a"
        let url = tempDir.appendingPathComponent(fileName)
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder?.isMeteringEnabled = true
        audioRecorder?.delegate = self
        // record() returning false means capture never started (no input
        // device — e.g. a Mac mini without a microphone — or the audio
        // engine refused). Ignoring it left the UI stuck on
        // "Recording 0:00" and the eventual stop silently discarded a
        // zero-length take (audit round 16 live finding, both platforms).
        guard audioRecorder?.record() == true else {
            audioRecorder = nil
            recordingURL = nil
            try? FileManager.default.removeItem(at: url)
            throw VoiceRecorderError.captureFailedToStart
        }

        isRecording = true
        duration = 0

        // Update duration every 0.1 seconds
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.duration = self.audioRecorder?.currentTime ?? 0
            }
        }

        // Update audio level for visualization
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.audioRecorder?.updateMeters()
                let level = self.audioRecorder?.averagePower(forChannel: 0) ?? -160
                // Normalize: -160 dB (silent) to 0 dB (max) -> 0.0 to 1.0
                self.audioLevel = max(0, (level + 50) / 50)
            }
        }
    }

    /// Stop recording and return the recorded audio file URL.
    public func stopRecording() -> URL? {
        guard isRecording else { return nil }

        durationTimer?.invalidate()
        durationTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil

        audioRecorder?.stop()
        isRecording = false
        audioLevel = 0

        let url = recordingURL
        recordingURL = nil
        audioRecorder = nil

        return url
    }

    /// Cancel recording and delete the temp file.
    public func cancelRecording() {
        durationTimer?.invalidate()
        durationTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil

        audioRecorder?.stop()
        isRecording = false
        audioLevel = 0

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        audioRecorder = nil
    }

    /// Request microphone permission.
    public static func requestPermission() async -> Bool {
        await PlatformDependencies.shared.audioSession().requestRecordPermission()
    }

    /// Check if microphone permission is granted.
    public static var hasPermission: Bool {
        PlatformDependencies.shared.audioSession().recordPermissionGranted
    }
}

extension VoiceRecorder: AVAudioRecorderDelegate {
    public nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag {
                self.cancelRecording()
            }
        }
    }

    public nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.cancelRecording()
        }
    }
}
