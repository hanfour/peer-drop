import Foundation
import os

private let logger = Logger(subsystem: "com.peerdrop.app", category: "ChatManager")

@MainActor
final class ChatManager: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var groupMessages: [ChatMessage] = []
    @Published private(set) var unreadCounts: [String: Int] = [:]
    @Published private(set) var groupUnreadCounts: [String: Int] = [:]
    @Published var activeChatPeerID: String?
    @Published var activeGroupID: String?
    @Published var typingPeers: Set<String> = []

    private var typingExpirationTasks: [String: Task<Void, Never>] = [:]

    var totalUnread: Int { unreadCounts.values.reduce(0, +) + groupUnreadCounts.values.reduce(0, +) }

    private let fileManager = FileManager.default
    private let unreadKey = "peerDropUnreadCounts"
    private let groupUnreadKey = "peerDropGroupUnreadCounts"
    private let encryptor = ChatDataEncryptor.shared

    init() {
        loadUnreadCounts()
        loadGroupUnreadCounts()
    }

    private var chatDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ChatData", isDirectory: true)
    }

    private func mediaDirectory(for peerID: String) -> URL {
        chatDirectory.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(peerID, isDirectory: true)
    }

    private func messagesFile(for peerID: String) -> URL {
        chatDirectory.appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(peerID).json")
    }

    private func groupMessagesFile(for groupID: String) -> URL {
        chatDirectory.appendingPathComponent("group_messages", isDirectory: true)
            .appendingPathComponent("\(groupID).json")
    }

    @discardableResult
    func saveOutgoing(text: String, peerID: String, peerName: String, replyTo: ChatMessage? = nil) -> ChatMessage {
        let msg = ChatMessage.text(text: text, isOutgoing: true, peerName: peerName, replyTo: replyTo)
        appendMessage(msg, peerID: peerID)
        return msg
    }

    @discardableResult
    func saveIncoming(text: String, peerID: String, peerName: String, groupID: String? = nil, senderID: String? = nil, senderName: String? = nil, replyToMessageID: String? = nil, replyToText: String? = nil, replyToSenderName: String? = nil) -> ChatMessage {
        let msg = ChatMessage(
            id: UUID().uuidString,
            text: text,
            isMedia: false,
            mediaType: nil,
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            duration: nil,
            thumbnailData: nil,
            localFileURL: nil,
            isOutgoing: false,
            peerName: peerName,
            status: .delivered,
            timestamp: Date(),
            groupID: groupID,
            senderID: senderID,
            senderName: senderName ?? peerName,
            replyToMessageID: replyToMessageID,
            replyToText: replyToText,
            replyToSenderName: replyToSenderName
        )
        appendMessage(msg, peerID: peerID)
        if activeChatPeerID != peerID {
            incrementUnread(peerID: peerID)
        }
        return msg
    }

    @discardableResult
    func saveOutgoingMedia(mediaType: MediaMessagePayload.MediaType, fileName: String, fileSize: Int64, mimeType: String, duration: Double?, localFileURL: String?, thumbnailData: Data?, peerID: String, peerName: String) -> ChatMessage {
        let msg = ChatMessage.media(mediaType: mediaType.rawValue, fileName: fileName, fileSize: fileSize, mimeType: mimeType, duration: duration, localFileURL: localFileURL, thumbnailData: thumbnailData, isOutgoing: true, peerName: peerName)
        appendMessage(msg, peerID: peerID)
        return msg
    }

    func saveIncomingMedia(payload: MediaMessagePayload, fileData: Data, peerID: String, peerName: String) {
        let relativePath = saveMediaFile(data: fileData, fileName: payload.fileName, peerID: peerID)
        let msg = ChatMessage.media(mediaType: payload.mediaType.rawValue, fileName: payload.fileName, fileSize: payload.fileSize, mimeType: payload.mimeType, duration: payload.duration, localFileURL: relativePath, thumbnailData: payload.thumbnailData, isOutgoing: false, peerName: peerName)
        appendMessage(msg, peerID: peerID)
        if activeChatPeerID != peerID {
            incrementUnread(peerID: peerID)
        }
    }

    func loadMessages(forPeer peerID: String) {
        // Screenshot mode: return mock messages for mock peers
        if ScreenshotModeProvider.shared.isActive && ScreenshotModeProvider.isMockPeer(peerID) {
            messages = ScreenshotModeProvider.shared.mockChatMessages
            return
        }

        let file = messagesFile(for: peerID)
        guard fileManager.fileExists(atPath: file.path) else {
            messages = []
            markAsRead(peerID: peerID)
            return
        }
        do {
            let raw = try Data(contentsOf: file)
            let data = try encryptor.decrypt(raw)
            messages = try JSONDecoder().decode([ChatMessage].self, from: data)
        } catch {
            messages = []
        }
        markAsRead(peerID: peerID)
    }

    func deleteMessages(forPeer peerID: String) {
        let file = messagesFile(for: peerID)
        do {
            try fileManager.removeItem(at: file)
        } catch {
            logger.warning("Failed to delete messages file: \(error.localizedDescription)")
        }
        let mediaDir = mediaDirectory(for: peerID)
        do {
            try fileManager.removeItem(at: mediaDir)
        } catch {
            logger.warning("Failed to delete media directory: \(error.localizedDescription)")
        }
        if !messages.isEmpty {
            messages = []
        }
    }

    @discardableResult
    func saveMediaFile(data: Data, fileName: String, peerID: String) -> String {
        let dir = mediaDirectory(for: peerID)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let uniqueName = "\(UUID().uuidString.prefix(8))_\(fileName)"
        let fileURL = dir.appendingPathComponent(uniqueName)
        try? encryptor.encryptAndWrite(data, to: fileURL)
        return "\(peerID)/\(uniqueName)"
    }

    func loadMediaData(relativePath: String) -> Data? {
        let url = resolveMediaURL(relativePath)
        return try? encryptor.readAndDecrypt(from: url)
    }

    func resolveMediaURL(_ relativePath: String) -> URL {
        chatDirectory.appendingPathComponent("media", isDirectory: true).appendingPathComponent(relativePath)
    }

    /// Write media to a temporary file for video playback.
    func writeMediaToTempFile(relativePath: String) -> URL? {
        guard let data = loadMediaData(relativePath: relativePath) else { return nil }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = (relativePath as NSString).lastPathComponent
        let tempURL = tempDir.appendingPathComponent("media_\(UUID().uuidString)_\(fileName)")

        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }

    func updateStatus(messageID: String, status: MessageStatus) {
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages[idx].status = status
        }
        let messagesDir = chatDirectory.appendingPathComponent("messages", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: messagesDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let raw = try? Data(contentsOf: file),
                  let decrypted = try? encryptor.decrypt(raw),
                  var msgs = try? JSONDecoder().decode([ChatMessage].self, from: decrypted) else { continue }
            if let idx = msgs.firstIndex(where: { $0.id == messageID }) {
                msgs[idx].status = status
                if let encoded = try? JSONEncoder().encode(msgs) {
                    try? encryptor.encryptAndWrite(encoded, to: file)
                }
                return
            }
        }
    }

    func markLastOutgoingAsFailed(peerID: String, errorText: String) {
        // Find the last outgoing message in the in-memory list and mark it failed
        if let idx = messages.lastIndex(where: { $0.isOutgoing }) {
            messages[idx].status = .failed
            updateStatus(messageID: messages[idx].id, status: .failed)
        }
    }

    // MARK: - Group Read Status

    /// Update group message status for a specific message.
    func updateGroupMessageStatus(messageID: String, status: MessageStatus) {
        if let idx = groupMessages.firstIndex(where: { $0.id == messageID }) {
            groupMessages[idx].status = status
        }
        // Also persist to disk
        updateStatus(messageID: messageID, status: status)
    }

    /// Mark a group message as delivered to a specific peer.
    func markGroupMessageDelivered(messageID: String, groupID: String, to peerID: String) {
        // Update in-memory
        if let idx = groupMessages.firstIndex(where: { $0.id == messageID }) {
            var status = groupMessages[idx].groupReadStatus ?? GroupReadStatus()
            status.deliveredTo.insert(peerID)
            groupMessages[idx].groupReadStatus = status
            persistGroupReadStatus(messageID: messageID, groupID: groupID, status: status)
        }
    }

    /// Mark a group message as read by a specific peer.
    func markGroupMessageRead(messageID: String, groupID: String, by peerID: String) {
        // Update in-memory
        if let idx = groupMessages.firstIndex(where: { $0.id == messageID }) {
            var status = groupMessages[idx].groupReadStatus ?? GroupReadStatus()
            status.deliveredTo.insert(peerID) // Read implies delivered
            status.readBy.insert(peerID)
            groupMessages[idx].groupReadStatus = status
            persistGroupReadStatus(messageID: messageID, groupID: groupID, status: status)
        }
    }

    private func persistGroupReadStatus(messageID: String, groupID: String, status: GroupReadStatus) {
        // Persist to group messages file
        let groupMessagesFile = chatDirectory
            .appendingPathComponent("group_messages", isDirectory: true)
            .appendingPathComponent("\(groupID).json")

        guard fileManager.fileExists(atPath: groupMessagesFile.path),
              let raw = try? Data(contentsOf: groupMessagesFile),
              let decrypted = try? encryptor.decrypt(raw),
              var msgs = try? JSONDecoder().decode([ChatMessage].self, from: decrypted) else {
            return
        }

        if let idx = msgs.firstIndex(where: { $0.id == messageID }) {
            msgs[idx].groupReadStatus = status
            if let encoded = try? JSONEncoder().encode(msgs) {
                try? encryptor.encryptAndWrite(encoded, to: groupMessagesFile)
            }
        }
    }

    // MARK: - Unread Tracking

    func markAsRead(peerID: String) {
        guard unreadCounts[peerID] != nil, unreadCounts[peerID] != 0 else { return }
        unreadCounts[peerID] = 0
        saveUnreadCounts()
    }

    // MARK: - Typing Indicator

    func setTyping(_ isTyping: Bool, for peerID: String) {
        typingExpirationTasks[peerID]?.cancel()

        if isTyping {
            typingPeers.insert(peerID)
            typingExpirationTasks[peerID] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000) // P2: sleep interruption is acceptable
                typingPeers.remove(peerID)
            }
        } else {
            typingPeers.remove(peerID)
        }
    }

    func isTyping(peerID: String) -> Bool {
        typingPeers.contains(peerID)
    }

    func getUnreadMessageIDs(for peerID: String) -> [String] {
        messages
            .filter { !$0.isOutgoing && $0.status != .read }
            .map { $0.id }
    }

    func message(byID messageID: String) -> ChatMessage? {
        messages.first { $0.id == messageID }
    }

    // MARK: - Reactions

    /// Add a reaction to a message.
    func addReaction(emoji: String, to messageID: String, from senderID: String) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }

        var reactions = messages[idx].reactions ?? [:]
        var senders = reactions[emoji] ?? []
        senders.insert(senderID)
        reactions[emoji] = senders
        messages[idx].reactions = reactions

        // Persist to disk
        persistReaction(messageID: messageID, reactions: reactions)
    }

    /// Remove a reaction from a message.
    func removeReaction(emoji: String, from messageID: String, by senderID: String) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }

        var reactions = messages[idx].reactions ?? [:]
        var senders = reactions[emoji] ?? []
        senders.remove(senderID)
        if senders.isEmpty {
            reactions.removeValue(forKey: emoji)
        } else {
            reactions[emoji] = senders
        }
        messages[idx].reactions = reactions.isEmpty ? nil : reactions

        // Persist to disk
        persistReaction(messageID: messageID, reactions: messages[idx].reactions)
    }

    private func persistReaction(messageID: String, reactions: [String: Set<String>]?) {
        let messagesDir = chatDirectory.appendingPathComponent("messages", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: messagesDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let raw = try? Data(contentsOf: file),
                  let decrypted = try? encryptor.decrypt(raw),
                  var msgs = try? JSONDecoder().decode([ChatMessage].self, from: decrypted) else { continue }
            if let idx = msgs.firstIndex(where: { $0.id == messageID }) {
                msgs[idx].reactions = reactions
                if let encoded = try? JSONEncoder().encode(msgs) {
                    try? encryptor.encryptAndWrite(encoded, to: file)
                }
                return
            }
        }
    }

    // MARK: - Search

    /// Search messages matching a query for a specific peer.
    func searchMessages(query: String, peerID: String) -> [ChatMessage] {
        let lowercasedQuery = query.lowercased()

        // Load all messages for this peer if not already loaded
        if messages.isEmpty {
            loadMessages(forPeer: peerID)
        }

        return messages.filter { message in
            // Search in text content
            if let text = message.text?.lowercased(), text.contains(lowercasedQuery) {
                return true
            }
            // Search in file names
            if let fileName = message.fileName?.lowercased(), fileName.contains(lowercasedQuery) {
                return true
            }
            return false
        }
        .sorted { $0.timestamp > $1.timestamp } // Most recent first
    }

    func incrementUnread(peerID: String) {
        unreadCounts[peerID, default: 0] += 1
        saveUnreadCounts()
    }

    private func loadUnreadCounts() {
        guard let data = UserDefaults.standard.data(forKey: unreadKey) else { return }
        do {
            unreadCounts = try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            logger.warning("Failed to decode unread counts: \(error.localizedDescription)")
        }
    }

    private func saveUnreadCounts() {
        do {
            let data = try JSONEncoder().encode(unreadCounts)
            UserDefaults.standard.set(data, forKey: unreadKey)
        } catch {
            logger.warning("Failed to save unread counts: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func appendMessage(_ message: ChatMessage, peerID: String) {
        let file = messagesFile(for: peerID)
        let dir = file.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create chat directory: \(error.localizedDescription)")
        }
        var existing: [ChatMessage] = []
        do {
            let raw = try Data(contentsOf: file)
            let decrypted = try encryptor.decrypt(raw)
            existing = try JSONDecoder().decode([ChatMessage].self, from: decrypted)
        } catch {
            // File doesn't exist yet or is corrupted — start fresh
            logger.debug("Loading existing messages: \(error.localizedDescription)")
        }
        existing.append(message)
        do {
            let encoded = try JSONEncoder().encode(existing)
            try encryptor.encryptAndWrite(encoded, to: file)
        } catch {
            logger.error("Failed to persist message: \(error.localizedDescription)")
        }
        messages.append(message)
    }

    // MARK: - Group Messages

    @discardableResult
    func saveGroupOutgoing(text: String, groupID: String, localName: String) -> ChatMessage {
        let msg = ChatMessage.text(
            text: text,
            isOutgoing: true,
            peerName: "Group",
            groupID: groupID,
            senderID: nil,
            senderName: localName
        )
        appendGroupMessage(msg, groupID: groupID)
        return msg
    }

    @discardableResult
    func saveGroupIncoming(text: String, groupID: String, senderID: String, senderName: String) -> ChatMessage {
        let msg = ChatMessage.text(
            text: text,
            isOutgoing: false,
            peerName: "Group",
            groupID: groupID,
            senderID: senderID,
            senderName: senderName
        )
        appendGroupMessage(msg, groupID: groupID)
        if activeGroupID != groupID {
            incrementGroupUnread(groupID: groupID)
        }
        return msg
    }

    func loadGroupMessages(forGroup groupID: String) {
        let file = groupMessagesFile(for: groupID)
        guard fileManager.fileExists(atPath: file.path) else {
            groupMessages = []
            markGroupAsRead(groupID: groupID)
            return
        }
        do {
            let raw = try Data(contentsOf: file)
            let data = try encryptor.decrypt(raw)
            groupMessages = try JSONDecoder().decode([ChatMessage].self, from: data)
        } catch {
            groupMessages = []
        }
        markGroupAsRead(groupID: groupID)
    }

    func deleteGroupMessages(forGroup groupID: String) {
        let file = groupMessagesFile(for: groupID)
        try? fileManager.removeItem(at: file)
        groupMessages = []
    }

    private func appendGroupMessage(_ message: ChatMessage, groupID: String) {
        let file = groupMessagesFile(for: groupID)
        let dir = file.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        var existing: [ChatMessage] = []
        if let raw = try? Data(contentsOf: file),
           let decrypted = try? encryptor.decrypt(raw) {
            existing = (try? JSONDecoder().decode([ChatMessage].self, from: decrypted)) ?? []
        }
        existing.append(message)
        if let encoded = try? JSONEncoder().encode(existing) {
            try? encryptor.encryptAndWrite(encoded, to: file)
        }
        groupMessages.append(message)
    }

    // MARK: - Group Unread Tracking

    func markGroupAsRead(groupID: String) {
        guard groupUnreadCounts[groupID] != nil, groupUnreadCounts[groupID] != 0 else { return }
        groupUnreadCounts[groupID] = 0
        saveGroupUnreadCounts()
    }

    func incrementGroupUnread(groupID: String) {
        groupUnreadCounts[groupID, default: 0] += 1
        saveGroupUnreadCounts()
    }

    func groupUnreadCount(for groupID: String) -> Int {
        groupUnreadCounts[groupID] ?? 0
    }

    private func loadGroupUnreadCounts() {
        guard let data = UserDefaults.standard.data(forKey: groupUnreadKey) else { return }
        do {
            groupUnreadCounts = try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            logger.warning("Failed to decode group unread counts: \(error.localizedDescription)")
        }
    }

    private func saveGroupUnreadCounts() {
        do {
            let data = try JSONEncoder().encode(groupUnreadCounts)
            UserDefaults.standard.set(data, forKey: groupUnreadKey)
        } catch {
            logger.warning("Failed to save group unread counts: \(error.localizedDescription)")
        }
    }

    // MARK: - Migration

    func migrateExistingDataToEncrypted() {
        let messagesDir = chatDirectory.appendingPathComponent("messages", isDirectory: true)
        if let files = try? fileManager.contentsOfDirectory(at: messagesDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                try? encryptor.migrateFileIfNeeded(at: file)
            }
        }

        let mediaDir = chatDirectory.appendingPathComponent("media", isDirectory: true)
        if let peerDirs = try? fileManager.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil) {
            for peerDir in peerDirs {
                guard let files = try? fileManager.contentsOfDirectory(at: peerDir, includingPropertiesForKeys: nil) else { continue }
                for file in files {
                    try? encryptor.migrateFileIfNeeded(at: file)
                }
            }
        }
    }
}
