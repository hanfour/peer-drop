import Foundation
import CallKit
import AVFoundation

/// Wraps CXProvider for native iOS call UI integration.
final class CallKitManager: NSObject, ObservableObject {
    private let provider: CXProvider
    private let callController = CXCallController()
    private var activeCallUUID: UUID?

    var onAnswerCall: (() -> Void)?
    var onEndCall: (() -> Void)?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.iconTemplateImageData = nil

        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // MARK: - Outgoing Call

    func startOutgoingCall(to peerName: String) {
        let uuid = UUID()
        activeCallUUID = uuid

        let handle = CXHandle(type: .generic, value: peerName)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = false

        let transaction = CXTransaction(action: startAction)
        callController.request(transaction) { error in
            if let error {
                print("[CallKit] Failed to start call: \(error)")
            }
        }
    }

    func reportOutgoingCallConnected() {
        guard let uuid = activeCallUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    // MARK: - Incoming Call

    func reportIncomingCall(from peerName: String) async throws {
        let uuid = UUID()
        activeCallUUID = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peerName)
        update.localizedCallerName = peerName
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false
        update.supportsDTMF = false

        try await provider.reportNewIncomingCall(with: uuid, update: update)
    }

    // MARK: - End Call

    func endCall() {
        guard let uuid = activeCallUUID else { return }

        let endAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endAction)
        callController.request(transaction) { error in
            if let error {
                print("[CallKit] Failed to end call: \(error)")
            }
        }
        activeCallUUID = nil
    }

    func reportCallEnded(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = activeCallUUID else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        activeCallUUID = nil
    }

    // MARK: - Audio

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat)
            try session.setActive(true)
        } catch {
            print("[CallKit] Audio session error: \(error)")
        }
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        activeCallUUID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudioSession()
        onAnswerCall?()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onEndCall?()
        activeCallUUID = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudioSession()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // WebRTC will use this audio session
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Clean up audio
    }
}
