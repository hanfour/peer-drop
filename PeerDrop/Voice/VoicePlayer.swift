import AVFoundation
import os

/// Plays voice messages using AVAudioPlayer.
@MainActor
final class VoicePlayer: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.peerdrop.app", category: "VoicePlayer")
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentMessageID: String?

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?

    override init() {
        super.init()
    }

    /// Play audio from a URL.
    func play(url: URL, messageID: String? = nil) {
        stop()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

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
    func play(data: Data, messageID: String? = nil) {
        stop()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

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
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    /// Resume playback.
    func resume() {
        guard audioPlayer != nil else { return }
        audioPlayer?.play()
        isPlaying = true
        startProgressTimer()
    }

    /// Toggle play/pause.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    /// Stop playback completely.
    func stop() {
        stopProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentMessageID = nil
    }

    /// Seek to a specific time.
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
    }

    /// Check if a specific message is currently playing.
    func isPlaying(messageID: String) -> Bool {
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
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopProgressTimer()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.stop()
        }
    }
}
