import Foundation
import Combine
import os.log

/// Manages the device's anonymous mailbox on the zero-knowledge relay.
/// Handles mailbox registration, message polling, pre-key upload, and rotation.
@MainActor
final class MailboxManager: ObservableObject {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "MailboxManager")

    @Published private(set) var mailboxId: String?
    @Published private(set) var isRegistered = false
    @Published private(set) var pendingMessages: [MailboxMessage] = []

    private let client: MailboxClient
    private let preKeyStore: PreKeyStore
    private var mailboxToken: String?
    private var pollTask: Task<Void, Never>?

    private static let mailboxIdKey = "peerDropMailboxId"

    var onMessageReceived: ((MailboxMessage) -> Void)?

    init(client: MailboxClient = MailboxClient(), preKeyStore: PreKeyStore = PreKeyStore()) {
        self.client = client
        self.preKeyStore = preKeyStore

        self.mailboxId = UserDefaults.standard.string(forKey: Self.mailboxIdKey)
        self.mailboxToken = loadTokenFromKeychain()
        self.isRegistered = mailboxId != nil && mailboxToken != nil
    }

    // MARK: - Registration

    func registerIfNeeded() async throws {
        guard !isRegistered else { return }

        let newMailboxId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased())
        let bundle = preKeyStore.generatePreKeyBundle()

        let token = try await client.registerPreKeys(mailboxId: newMailboxId, bundle: bundle)

        self.mailboxId = newMailboxId
        self.mailboxToken = token
        self.isRegistered = true

        UserDefaults.standard.set(mailboxId, forKey: Self.mailboxIdKey)
        saveTokenToKeychain(token)

        Self.logger.info("Mailbox registered: \(newMailboxId)")
    }

    // MARK: - Message Polling

    func startPolling(interval: TimeInterval = 30) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollMessages()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollMessages() async {
        guard let mailboxId, let token = mailboxToken else { return }
        do {
            let messages = try await client.fetchMessages(mailboxId: mailboxId, token: token)
            for msg in messages {
                pendingMessages.append(msg)
                onMessageReceived?(msg)
            }
        } catch {
            Self.logger.error("Failed to poll messages: \(error.localizedDescription)")
        }
    }

    // MARK: - Pre-Key Maintenance

    func uploadPreKeysIfNeeded() async {
        preKeyStore.rotateSignedPreKeyIfNeeded()
        preKeyStore.replenishOneTimePreKeysIfNeeded()

        guard let mailboxId, let token = mailboxToken else { return }
        let bundle = preKeyStore.generatePreKeyBundle()
        do {
            _ = try await client.registerPreKeys(mailboxId: mailboxId, bundle: bundle, token: token)
            Self.logger.info("Pre-keys uploaded successfully")
        } catch {
            Self.logger.error("Failed to upload pre-keys: \(error.localizedDescription)")
        }
    }

    // MARK: - Mailbox Rotation

    func rotateMailbox() async throws {
        guard let oldId = mailboxId, let oldToken = mailboxToken else { return }
        let result = try await client.rotateMailbox(oldMailboxId: oldId, oldToken: oldToken)

        self.mailboxId = result.newMailboxId
        self.mailboxToken = result.newToken

        UserDefaults.standard.set(result.newMailboxId, forKey: Self.mailboxIdKey)
        saveTokenToKeychain(result.newToken)

        Self.logger.info("Mailbox rotated to: \(result.newMailboxId)")
    }

    // MARK: - Keychain Token Storage

    private static let keychainService = "com.peerdrop.mailbox"
    private static let keychainAccount = "mailbox-token"

    private func saveTokenToKeychain(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
