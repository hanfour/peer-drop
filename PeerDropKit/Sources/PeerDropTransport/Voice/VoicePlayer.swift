import AVFoundation
import PeerDropPlatform
import os

/// Plays voice messages using AVAudioPlayer.
@MainActor
public final class VoicePlayer: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "VoicePlayer")
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var currentMessageID: String?

    private let audioSession: AudioSessionConfiguring
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?

    public init(audioSession: AudioSessionConfiguring = PlatformDependencies.shared.audioSession()) {
        self.audioSession = audioSession
        super.init()
    }

    /// Play audio from a URL.
    public func play(url: URL, messageID: String? = nil) {
        stop()

        do {
            try audioSession.activate(.playback)

            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()

            duration = audioPlayer?.duration ?? 0
            currentTime = 0
            currentMessageID = messageID
            isPlaying = true

            audioPlayer?.play()
            startProgressTimer()
        } catch {
            logger.error("Failed to play: \(error.localizedDescription)")
        }
    }

    /// Play audio from Data.
    public func play(data: Data, messageID: String? = nil) {
        stop()

        do {
            try audioSession.activate(.playback)

            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()

            duration = audioPlayer?.duration ?? 0
            currentTime = 0
            currentMessageID = messageID
            isPlaying = true

            audioPlayer?.play()
            startProgressTimer()
        } catch {
            logger.error("Failed to play data: \(error.localizedDescription)")
        }
    }

    /// Pause playback.
    public func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    /// Resume playback.
    public func resume() {
        guard audioPlayer != nil else { return }
        audioPlayer?.play()
        isPlaying = true
        startProgressTimer()
    }

    /// Toggle play/pause.
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    /// Stop playback completely.
    public func stop() {
        stopProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentMessageID = nil
    }

    /// Seek to a specific time.
    public func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
    }

    /// Check if a specific message is currently playing.
    public func isPlaying(messageID: String) -> Bool {
        isPlaying && currentMessageID == messageID
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.currentTime = self.audioPlayer?.currentTime ?? 0
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

extension VoicePlayer: AVAudioPlayerDelegate {
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopProgressTimer()
        }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.stop()
        }
    }
}
