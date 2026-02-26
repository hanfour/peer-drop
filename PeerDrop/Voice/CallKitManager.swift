import Foundation
import CallKit
import AVFoundation
import os

/// Wraps CXProvider for native iOS call UI integration.
/// CallKit is disabled in China per MIIT regulations (App Store Guideline 5.0).
final class CallKitManager: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "CallKitManager")
    private let provider: CXProvider?
    private let callController: CXCallController?
    private var activeCallUUID: UUID?

    /// CallKit is disabled in China per MIIT regulations (App Store Guideline 5.0).
    static let isCallKitDisabled: Bool = {
        if let regionCode = Locale.current.region?.identifier {
            if regionCode == "CN" { return true }
        }
        let countryCode = Locale.current.language.region?.identifier ?? ""
        return countryCode == "CN"
    }()

    var onAnswerCall: (() -> Void)?
    var onEndCall: (() -> Void)?

    override init() {
        if Self.isCallKitDisabled {
            provider = nil
            callController = nil
            super.init()
            return
        }

        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.iconTemplateImageData = nil

        let p = CXProvider(configuration: config)
        provider = p
        callController = CXCallController()
        super.init()
        p.setDelegate(self, queue: .main)
    }

    // MARK: - Outgoing Call

    func startOutgoingCall(to peerName: String) {
        guard !Self.isCallKitDisabled, let callController else { return }

        let uuid = UUID()
        activeCallUUID = uuid

        let handle = CXHandle(type: .generic, value: peerName)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = false

        let transaction = CXTransaction(action: startAction)
        callController.request(transaction) { error in
            if let error {
                self.logger.error("Failed to start call: \(error.localizedDescription)")
            }
        }
    }

    func reportOutgoingCallConnected() {
        guard !Self.isCallKitDisabled, let provider else { return }
        guard let uuid = activeCallUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    // MARK: - Incoming Call

    func reportIncomingCall(from peerName: String) async throws {
        guard !Self.isCallKitDisabled, let provider else { return }

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
        guard !Self.isCallKitDisabled, let callController else { return }
        guard let uuid = activeCallUUID else { return }

        let endAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endAction)
        callController.request(transaction) { error in
            if let error {
                self.logger.error("Failed to end call: \(error.localizedDescription)")
            }
        }
        activeCallUUID = nil
    }

    func reportCallEnded(reason: CXCallEndedReason = .remoteEnded) {
        guard !Self.isCallKitDisabled, let provider else { return }
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
            logger.error("Audio session error: \(error.localizedDescription)")
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
