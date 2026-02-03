import Foundation

@MainActor
final class ChatManager: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var unreadCounts: [String: Int] = [:]
    @Published var activeChatPeerID: String?

    var totalUnread: Int { unreadCounts.values.reduce(0, +) }

    private let fileManager = FileManager.default
    private let unreadKey = "peerDropUnreadCounts"

    init() {
        loadUnreadCounts()
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

    @discardableResult
    func saveOutgoing(text: String, peerID: String, peerName: String) -> ChatMessage {
        let msg = ChatMessage.text(text: text, isOutgoing: true, peerName: peerName)
        appendMessage(msg, peerID: peerID)
        return msg
    }

    @discardableResult
    func saveIncoming(text: String, peerID: String, peerName: String) -> ChatMessage {
        let msg = ChatMessage.text(text: text, isOutgoing: false, peerName: peerName)
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
        let file = messagesFile(for: peerID)
        guard fileManager.fileExists(atPath: file.path) else {
            messages = []
            markAsRead(peerID: peerID)
            return
        }
        do {
            let data = try Data(contentsOf: file)
            messages = try JSONDecoder().decode([ChatMessage].self, from: data)
        } catch {
            messages = []
        }
        markAsRead(peerID: peerID)
    }

    func deleteMessages(forPeer peerID: String) {
        let file = messagesFile(for: peerID)
        try? fileManager.removeItem(at: file)
        let mediaDir = mediaDirectory(for: peerID)
        try? fileManager.removeItem(at: mediaDir)
        if messages.first(where: { _ in true }) != nil {
            messages = []
        }
    }

    @discardableResult
    func saveMediaFile(data: Data, fileName: String, peerID: String) -> String {
        let dir = mediaDirectory(for: peerID)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let uniqueName = "\(UUID().uuidString.prefix(8))_\(fileName)"
        let fileURL = dir.appendingPathComponent(uniqueName)
        try? data.write(to: fileURL)
        return "\(peerID)/\(uniqueName)"
    }

    func resolveMediaURL(_ relativePath: String) -> URL {
        chatDirectory.appendingPathComponent("media", isDirectory: true).appendingPathComponent(relativePath)
    }

    func updateStatus(messageID: String, status: MessageStatus) {
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages[idx].status = status
        }
        let messagesDir = chatDirectory.appendingPathComponent("messages", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: messagesDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var msgs = try? JSONDecoder().decode([ChatMessage].self, from: data) else { continue }
            if let idx = msgs.firstIndex(where: { $0.id == messageID }) {
                msgs[idx].status = status
                if let encoded = try? JSONEncoder().encode(msgs) {
                    try? encoded.write(to: file)
                }
                return
            }
        }
    }

    // MARK: - Unread Tracking

    func markAsRead(peerID: String) {
        guard unreadCounts[peerID] != nil, unreadCounts[peerID] != 0 else { return }
        unreadCounts[peerID] = 0
        saveUnreadCounts()
    }

    func incrementUnread(peerID: String) {
        unreadCounts[peerID, default: 0] += 1
        saveUnreadCounts()
    }

    private func loadUnreadCounts() {
        guard let data = UserDefaults.standard.data(forKey: unreadKey),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        unreadCounts = decoded
    }

    private func saveUnreadCounts() {
        guard let data = try? JSONEncoder().encode(unreadCounts) else { return }
        UserDefaults.standard.set(data, forKey: unreadKey)
    }

    // MARK: - Private

    private func appendMessage(_ message: ChatMessage, peerID: String) {
        let file = messagesFile(for: peerID)
        let dir = file.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        var existing: [ChatMessage] = []
        if let data = try? Data(contentsOf: file) {
            existing = (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
        }
        existing.append(message)
        if let encoded = try? JSONEncoder().encode(existing) {
            try? encoded.write(to: file)
        }
        messages.append(message)
    }
}
