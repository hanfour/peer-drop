import Foundation
import CryptoKit

/// A message encrypted by the Double Ratchet, ready for wire transmission.
struct RatchetMessage: Codable {
    let ratchetKey: Data        // Sender's current DH ratchet public key
    let counter: UInt32         // Message number in current chain
    let previousCounter: UInt32 // Length of previous sending chain
    let ciphertext: Data        // AES-256-GCM encrypted (nonce + ciphertext + tag)
}

/// Double Ratchet session providing per-message forward secrecy.
/// Reference: https://signal.org/docs/specifications/doubleratchet/
class DoubleRatchetSession: Codable {

    // DH Ratchet state
    private var myRatchetKey: Curve25519.KeyAgreement.PrivateKey
    private var theirRatchetKey: Curve25519.KeyAgreement.PublicKey?

    // Symmetric Ratchet state
    private var rootKey: SymmetricKey
    private var sendChainKey: SymmetricKey?
    private var receiveChainKey: SymmetricKey?

    // Message counters
    private var sendCounter: UInt32 = 0
    private var receiveCounter: UInt32 = 0
    private var previousSendCounter: UInt32 = 0

    // Skipped message keys for out-of-order delivery
    private var skippedKeys: [SkippedKeyIndex: SymmetricKey] = [:]
    private static let maxSkip: UInt32 = 200

    private struct SkippedKeyIndex: Hashable, Codable {
        let ratchetKey: Data
        let counter: UInt32
    }

    private init(rootKey: SymmetricKey, myRatchetKey: Curve25519.KeyAgreement.PrivateKey) {
        self.rootKey = rootKey
        self.myRatchetKey = myRatchetKey
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case myRatchetKey, theirRatchetKey, rootKey
        case sendChainKey, receiveChainKey
        case sendCounter, receiveCounter, previousSendCounter
        case skippedKeys
    }

    /// Helper struct for serializing the `[SkippedKeyIndex: SymmetricKey]` dictionary
    /// since `SkippedKeyIndex` cannot serve as a JSON dictionary key directly.
    private struct SkippedKeyEntry: Codable {
        let ratchetKey: Data
        let counter: UInt32
        let messageKey: Data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(myRatchetKey.rawRepresentation, forKey: .myRatchetKey)
        try container.encodeIfPresent(theirRatchetKey?.rawRepresentation, forKey: .theirRatchetKey)
        try container.encode(rootKey.withUnsafeBytes { Data($0) }, forKey: .rootKey)
        try container.encodeIfPresent(sendChainKey.map { $0.withUnsafeBytes { Data($0) } }, forKey: .sendChainKey)
        try container.encodeIfPresent(receiveChainKey.map { $0.withUnsafeBytes { Data($0) } }, forKey: .receiveChainKey)
        try container.encode(sendCounter, forKey: .sendCounter)
        try container.encode(receiveCounter, forKey: .receiveCounter)
        try container.encode(previousSendCounter, forKey: .previousSendCounter)

        let entries = skippedKeys.map { (index, key) in
            SkippedKeyEntry(
                ratchetKey: index.ratchetKey,
                counter: index.counter,
                messageKey: key.withUnsafeBytes { Data($0) }
            )
        }
        try container.encode(entries, forKey: .skippedKeys)
    }

    required convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rootKeyData = try container.decode(Data.self, forKey: .rootKey)
        let myRatchetKeyData = try container.decode(Data.self, forKey: .myRatchetKey)

        self.init(
            rootKey: SymmetricKey(data: rootKeyData),
            myRatchetKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myRatchetKeyData)
        )

        if let theirData = try container.decodeIfPresent(Data.self, forKey: .theirRatchetKey) {
            self.theirRatchetKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirData)
        }
        if let sendData = try container.decodeIfPresent(Data.self, forKey: .sendChainKey) {
            self.sendChainKey = SymmetricKey(data: sendData)
        }
        if let recvData = try container.decodeIfPresent(Data.self, forKey: .receiveChainKey) {
            self.receiveChainKey = SymmetricKey(data: recvData)
        }

        self.sendCounter = try container.decode(UInt32.self, forKey: .sendCounter)
        self.receiveCounter = try container.decode(UInt32.self, forKey: .receiveCounter)
        self.previousSendCounter = try container.decode(UInt32.self, forKey: .previousSendCounter)

        let entries = try container.decode([SkippedKeyEntry].self, forKey: .skippedKeys)
        for entry in entries {
            let index = SkippedKeyIndex(ratchetKey: entry.ratchetKey, counter: entry.counter)
            self.skippedKeys[index] = SymmetricKey(data: entry.messageKey)
        }
    }

    // MARK: - Initialization

    /// Alice (initiator) initializes after X3DH.
    static func initializeAsInitiator(
        rootKey: SymmetricKey,
        theirRatchetKey: Curve25519.KeyAgreement.PublicKey
    ) -> DoubleRatchetSession {
        let myRatchetKey = Curve25519.KeyAgreement.PrivateKey()
        let session = DoubleRatchetSession(rootKey: rootKey, myRatchetKey: myRatchetKey)
        session.theirRatchetKey = theirRatchetKey

        let (newRootKey, sendChain) = session.dhRatchetStep(
            rootKey: rootKey,
            myKey: myRatchetKey,
            theirKey: theirRatchetKey
        )
        session.rootKey = newRootKey
        session.sendChainKey = sendChain
        return session
    }

    /// Bob (responder) initializes after X3DH.
    static func initializeAsResponder(
        rootKey: SymmetricKey,
        myRatchetKey: Curve25519.KeyAgreement.PrivateKey
    ) -> DoubleRatchetSession {
        DoubleRatchetSession(rootKey: rootKey, myRatchetKey: myRatchetKey)
    }

    // MARK: - Encrypt

    func encrypt(_ plaintext: Data) throws -> RatchetMessage {
        guard let chainKey = sendChainKey else {
            throw DoubleRatchetError.noSendChain
        }

        let (messageKey, newChainKey) = symmetricRatchetStep(chainKey: chainKey)
        sendChainKey = newChainKey

        let sealedBox = try AES.GCM.seal(plaintext, using: messageKey)
        guard let combined = sealedBox.combined else {
            throw DoubleRatchetError.encryptionFailed
        }

        let message = RatchetMessage(
            ratchetKey: myRatchetKey.publicKey.rawRepresentation,
            counter: sendCounter,
            previousCounter: previousSendCounter,
            ciphertext: combined
        )
        sendCounter += 1
        return message
    }

    // MARK: - Decrypt

    func decrypt(_ message: RatchetMessage) throws -> Data {
        // Check skipped keys first (out-of-order message)
        let skipIndex = SkippedKeyIndex(ratchetKey: message.ratchetKey, counter: message.counter)
        if let skippedKey = skippedKeys.removeValue(forKey: skipIndex) {
            return try decryptWithKey(message.ciphertext, key: skippedKey)
        }

        // Check if this is a new DH ratchet key
        if theirRatchetKey == nil || message.ratchetKey != theirRatchetKey!.rawRepresentation {
            // Skip any remaining messages from the old chain
            if let oldChain = receiveChainKey, let oldTheirKey = theirRatchetKey {
                receiveChainKey = try skipMessages(
                    until: message.previousCounter,
                    chainKey: oldChain,
                    theirRatchetKey: oldTheirKey.rawRepresentation
                )
            }

            // DH Ratchet step: derive new receive chain
            let newTheirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.ratchetKey)
            let (rootKey1, receiveChain) = dhRatchetStep(rootKey: rootKey, myKey: myRatchetKey, theirKey: newTheirKey)

            // Generate new ratchet key pair for sending
            previousSendCounter = sendCounter
            sendCounter = 0
            receiveCounter = 0
            theirRatchetKey = newTheirKey

            let newMyRatchetKey = Curve25519.KeyAgreement.PrivateKey()
            let (rootKey2, sendChain) = dhRatchetStep(rootKey: rootKey1, myKey: newMyRatchetKey, theirKey: newTheirKey)

            myRatchetKey = newMyRatchetKey
            rootKey = rootKey2
            sendChainKey = sendChain
            receiveChainKey = receiveChain
        }

        guard let chainKey = receiveChainKey else {
            throw DoubleRatchetError.noReceiveChain
        }

        // Skip ahead if needed
        let chainAfterSkip = try skipMessages(
            until: message.counter,
            chainKey: chainKey,
            theirRatchetKey: message.ratchetKey
        )

        // Derive message key
        let (messageKey, newChainKey) = symmetricRatchetStep(chainKey: chainAfterSkip)
        receiveChainKey = newChainKey
        receiveCounter = message.counter + 1

        return try decryptWithKey(message.ciphertext, key: messageKey)
    }

    // MARK: - Private

    private func dhRatchetStep(
        rootKey: SymmetricKey,
        myKey: Curve25519.KeyAgreement.PrivateKey,
        theirKey: Curve25519.KeyAgreement.PublicKey
    ) -> (newRootKey: SymmetricKey, chainKey: SymmetricKey) {
        let shared = try! myKey.sharedSecretFromKeyAgreement(with: theirKey)
        // ⚠️ Same CryptoKit workaround as X3DH — see X3DH.swift comment
        let sharedData: Data = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: Data(), outputByteCount: 32
        ).withUnsafeBytes { Data($0) }

        let info = "PeerDrop-Ratchet-v1".data(using: .utf8)!
        var salt = Data()
        rootKey.withUnsafeBytes { salt.append(contentsOf: $0) }

        let prk = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: sharedData, using: SymmetricKey(data: salt))))

        var t1Input = info; t1Input.append(0x01)
        let newRoot = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: t1Input, using: prk)))

        var t2Input = Data(HMAC<SHA256>.authenticationCode(for: t1Input, using: prk))
        t2Input.append(contentsOf: info); t2Input.append(0x02)
        let chain = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: t2Input, using: prk)))

        return (newRoot, chain)
    }

    private func symmetricRatchetStep(chainKey: SymmetricKey) -> (messageKey: SymmetricKey, newChainKey: SymmetricKey) {
        let msgKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
            for: Data([0x01]), using: chainKey
        )))
        let newChain = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
            for: Data([0x02]), using: chainKey
        )))
        return (msgKey, newChain)
    }

    /// Skip message keys up to `target` counter, storing them for out-of-order delivery.
    /// Returns the chain key after skipping.
    private func skipMessages(until target: UInt32, chainKey: SymmetricKey, theirRatchetKey: Data) throws -> SymmetricKey {
        guard target > receiveCounter else { return chainKey }
        guard target - receiveCounter <= Self.maxSkip else {
            throw DoubleRatchetError.tooManySkippedMessages
        }

        var currentChain = chainKey
        for i in receiveCounter..<target {
            let (msgKey, newChain) = symmetricRatchetStep(chainKey: currentChain)
            skippedKeys[SkippedKeyIndex(ratchetKey: theirRatchetKey, counter: i)] = msgKey
            currentChain = newChain
        }
        return currentChain
    }

    private func decryptWithKey(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    enum DoubleRatchetError: Error {
        case noSendChain
        case noReceiveChain
        case encryptionFailed
        case tooManySkippedMessages
    }
}
