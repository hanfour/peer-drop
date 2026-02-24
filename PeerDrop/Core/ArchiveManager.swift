import Foundation
import UIKit

enum ArchiveManager {
    struct Manifest: Codable {
        let version: Int
        let exportDate: Date
        let deviceName: String
    }

    enum ArchiveError: Error, LocalizedError {
        case invalidArchive, missingManifest
        var errorDescription: String? {
            switch self {
            case .invalidArchive: return "The archive is invalid or corrupted."
            case .missingManifest: return "The archive is missing a manifest."
            }
        }
    }

    @MainActor
    static func exportArchive(deviceStore: DeviceRecordStore, transferHistory: [TransferRecord], chatManager: ChatManager) async throws -> URL {
        let fm = FileManager.default
        let archiveDir = fm.temporaryDirectory.appendingPathComponent("PeerDropArchive", isDirectory: true)
        try? fm.removeItem(at: archiveDir)
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let manifest = Manifest(version: 1, exportDate: Date(), deviceName: UIDevice.current.name)
        try JSONEncoder().encode(manifest).write(to: archiveDir.appendingPathComponent("manifest.json"))
        try JSONEncoder().encode(deviceStore.records).write(to: archiveDir.appendingPathComponent("device_records.json"))
        try JSONEncoder().encode(transferHistory).write(to: archiveDir.appendingPathComponent("transfer_history.json"))
        try JSONEncoder().encode(chatManager.unreadCounts).write(to: archiveDir.appendingPathComponent("unread_counts.json"))

        let encryptor = ChatDataEncryptor.shared
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let chatMessagesDir = docs.appendingPathComponent("ChatData/messages", isDirectory: true)
        if fm.fileExists(atPath: chatMessagesDir.path) {
            let destMessages = archiveDir.appendingPathComponent("messages", isDirectory: true)
            try fm.createDirectory(at: destMessages, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: chatMessagesDir, includingPropertiesForKeys: nil)) ?? [] {
                let data = try encryptor.readAndDecrypt(from: file)
                try data.write(to: destMessages.appendingPathComponent(file.lastPathComponent))
            }
        }
        let chatMediaDir = docs.appendingPathComponent("ChatData/media", isDirectory: true)
        if fm.fileExists(atPath: chatMediaDir.path) {
            let destMedia = archiveDir.appendingPathComponent("media", isDirectory: true)
            try fm.createDirectory(at: destMedia, withIntermediateDirectories: true)
            for peerDir in (try? fm.contentsOfDirectory(at: chatMediaDir, includingPropertiesForKeys: nil)) ?? [] {
                let destPeer = destMedia.appendingPathComponent(peerDir.lastPathComponent)
                try fm.createDirectory(at: destPeer, withIntermediateDirectories: true)
                for file in (try? fm.contentsOfDirectory(at: peerDir, includingPropertiesForKeys: nil)) ?? [] {
                    let data = try encryptor.readAndDecrypt(from: file)
                    try data.write(to: destPeer.appendingPathComponent(file.lastPathComponent))
                }
            }
        }

        let zipURL = try await archiveDir.zipDirectory()
        try? fm.removeItem(at: archiveDir)
        return zipURL
    }

    @MainActor
    static func importArchive(from url: URL, merge: Bool, deviceStore: DeviceRecordStore, connectionManager: ConnectionManager) throws {
        let fm = FileManager.default
        guard url.startAccessingSecurityScopedResource() else { throw ArchiveError.invalidArchive }
        defer { url.stopAccessingSecurityScopedResource() }

        let extractedDir = try url.unzipFile()
        defer { try? fm.removeItem(at: extractedDir) }

        let contentDir: URL
        if fm.fileExists(atPath: extractedDir.appendingPathComponent("manifest.json").path) {
            contentDir = extractedDir
        } else {
            let contents = (try? fm.contentsOfDirectory(at: extractedDir, includingPropertiesForKeys: nil)) ?? []
            if let nested = contents.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) {
                contentDir = nested
            } else { throw ArchiveError.missingManifest }
        }

        let manifestData = try Data(contentsOf: contentDir.appendingPathComponent("manifest.json"))
        _ = try JSONDecoder().decode(Manifest.self, from: manifestData)

        let recordsFile = contentDir.appendingPathComponent("device_records.json")
        if fm.fileExists(atPath: recordsFile.path) {
            let records = try JSONDecoder().decode([DeviceRecord].self, from: Data(contentsOf: recordsFile))
            if merge { deviceStore.mergeImported(records) } else { deviceStore.replaceAll(with: records) }
        }

        let historyFile = contentDir.appendingPathComponent("transfer_history.json")
        if fm.fileExists(atPath: historyFile.path) {
            let history = try JSONDecoder().decode([TransferRecord].self, from: Data(contentsOf: historyFile))
            if merge {
                let existingIDs = Set(connectionManager.transferHistory.map(\.id))
                let newRecords = history.filter { !existingIDs.contains($0.id) }
                connectionManager.transferHistory = (connectionManager.transferHistory + newRecords).sorted { $0.timestamp > $1.timestamp }
            } else { connectionManager.transferHistory = history }
        }

        let unreadFile = contentDir.appendingPathComponent("unread_counts.json")
        if fm.fileExists(atPath: unreadFile.path) {
            let counts = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: unreadFile))
            if let encoded = try? JSONEncoder().encode(counts) { UserDefaults.standard.set(encoded, forKey: "peerDropUnreadCounts") }
        }

        let encryptor = ChatDataEncryptor.shared
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let messagesSource = contentDir.appendingPathComponent("messages", isDirectory: true)
        if fm.fileExists(atPath: messagesSource.path) {
            let dest = docs.appendingPathComponent("ChatData/messages", isDirectory: true)
            if !merge { try? fm.removeItem(at: dest) }
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: messagesSource, includingPropertiesForKeys: nil)) ?? [] {
                let d = dest.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: d.path) && merge { continue }
                let plaintext = try Data(contentsOf: file)
                try encryptor.encryptAndWrite(plaintext, to: d)
            }
        }

        let mediaSource = contentDir.appendingPathComponent("media", isDirectory: true)
        if fm.fileExists(atPath: mediaSource.path) {
            let dest = docs.appendingPathComponent("ChatData/media", isDirectory: true)
            if !merge { try? fm.removeItem(at: dest) }
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for peerDir in (try? fm.contentsOfDirectory(at: mediaSource, includingPropertiesForKeys: nil)) ?? [] {
                let destPeer = dest.appendingPathComponent(peerDir.lastPathComponent)
                try? fm.createDirectory(at: destPeer, withIntermediateDirectories: true)
                for file in (try? fm.contentsOfDirectory(at: peerDir, includingPropertiesForKeys: nil)) ?? [] {
                    let d = destPeer.appendingPathComponent(file.lastPathComponent)
                    if fm.fileExists(atPath: d.path) && merge { continue }
                    let plaintext = try Data(contentsOf: file)
                    try encryptor.encryptAndWrite(plaintext, to: d)
                }
            }
        }
    }
}
