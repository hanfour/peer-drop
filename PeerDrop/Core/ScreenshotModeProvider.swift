import Foundation
import Network

/// Provides mock data for App Store screenshot capture mode.
/// Activated via `-SCREENSHOT_MODE 1` launch argument.
final class ScreenshotModeProvider {

    static let shared = ScreenshotModeProvider()

    private init() {}

    // MARK: - Mode Detection

    /// Check if screenshot mode is enabled via launch argument.
    var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-SCREENSHOT_MODE")
    }

    // MARK: - Localization

    private var isChineseLocale: Bool {
        let lang = Locale.preferredLanguages.first ?? "en"
        return lang.hasPrefix("zh")
    }

    // MARK: - Mock Peer IDs (stable for UI tests)

    static let mockPeerID1 = "MOCK-PEER-001-SCREENSHOT"
    static let mockPeerID2 = "MOCK-PEER-002-SCREENSHOT"
    static let mockPeerID3 = "MOCK-PEER-003-SCREENSHOT"
    static let mockPeerID4 = "MOCK-PEER-004-SCREENSHOT"
    static let mockConnectedPeerID = mockPeerID1

    // MARK: - Mock Discovered Peers

    /// Returns 4 mock discovered peers for the Nearby tab.
    var mockDiscoveredPeers: [DiscoveredPeer] {
        let names: [(en: String, zh: String)] = [
            ("Sarah's MacBook Pro", "小美的 MacBook Pro"),
            ("James's iPhone", "阿傑的 iPhone"),
            ("Emily's iPad", "小雯的 iPad"),
            ("Dad's iPhone", "爸爸的 iPhone")
        ]

        return [
            DiscoveredPeer(
                id: Self.mockPeerID1,
                displayName: isChineseLocale ? names[0].zh : names[0].en,
                endpoint: .manual(host: "192.168.1.10", port: 54321),
                source: .bonjour,
                lastSeen: Date()
            ),
            DiscoveredPeer(
                id: Self.mockPeerID2,
                displayName: isChineseLocale ? names[1].zh : names[1].en,
                endpoint: .manual(host: "192.168.1.11", port: 54321),
                source: .bonjour,
                lastSeen: Date().addingTimeInterval(-60)
            ),
            DiscoveredPeer(
                id: Self.mockPeerID3,
                displayName: isChineseLocale ? names[2].zh : names[2].en,
                endpoint: .manual(host: "192.168.1.12", port: 54321),
                source: .bonjour,
                lastSeen: Date().addingTimeInterval(-120)
            ),
            DiscoveredPeer(
                id: Self.mockPeerID4,
                displayName: isChineseLocale ? names[3].zh : names[3].en,
                endpoint: .manual(host: "192.168.1.13", port: 54321),
                source: .bonjour,
                lastSeen: Date().addingTimeInterval(-180)
            )
        ]
    }

    // MARK: - Mock Connected Peer

    /// Returns a mock connected peer identity.
    var mockConnectedPeer: PeerIdentity {
        let name = isChineseLocale ? "小美的 MacBook Pro" : "Sarah's MacBook Pro"
        return PeerIdentity(
            id: Self.mockConnectedPeerID,
            displayName: name,
            certificateFingerprint: "MOCK-CERT-FINGERPRINT-123456"
        )
    }

    // MARK: - Mock Chat Messages

    /// Returns mock chat messages for the connected peer.
    var mockChatMessages: [ChatMessage] {
        let peerName = isChineseLocale ? "小美" : "Sarah"
        let now = Date()

        let messages: [(text: String, isOutgoing: Bool, minutesAgo: Int)] = isChineseLocale ? [
            ("嗨！你有空嗎？", false, 15),
            ("有啊，怎麼了？", true, 14),
            ("我想把假期的照片傳給你看", false, 12),
            ("好啊！用 PeerDrop 傳吧", true, 10),
            ("正在傳送中...", false, 5),
            ("收到了！照片好美！", true, 3),
            ("謝謝！下次一起出去玩吧", false, 1)
        ] : [
            ("Hey! Are you free?", false, 15),
            ("Yes, what's up?", true, 14),
            ("I want to share the vacation photos with you", false, 12),
            ("Sure! Let's use PeerDrop", true, 10),
            ("Sending now...", false, 5),
            ("Got them! Beautiful photos!", true, 3),
            ("Thanks! Let's hang out next time", false, 1)
        ]

        return messages.enumerated().map { index, msg in
            ChatMessage(
                id: "MOCK-MSG-\(index + 1)",
                text: msg.text,
                isMedia: false,
                mediaType: nil,
                fileName: nil,
                fileSize: nil,
                mimeType: nil,
                duration: nil,
                thumbnailData: nil,
                localFileURL: nil,
                isOutgoing: msg.isOutgoing,
                peerName: peerName,
                status: msg.isOutgoing ? .read : .delivered,
                timestamp: now.addingTimeInterval(TimeInterval(-msg.minutesAgo * 60))
            )
        }
    }

    // MARK: - Mock Device Records (Contacts)

    /// Returns mock device records for the Library/Contacts tab.
    var mockDeviceRecords: [DeviceRecord] {
        let records: [(en: String, zh: String, daysAgo: Int, count: Int)] = [
            ("Sarah's MacBook Pro", "小美的 MacBook Pro", 0, 15),
            ("James's iPhone", "阿傑的 iPhone", 1, 8),
            ("Emily's iPad", "小雯的 iPad", 3, 5),
            ("Mom's iPhone", "媽媽的 iPhone", 7, 12),
            ("Office iMac", "辦公室 iMac", 14, 3)
        ]

        return records.enumerated().map { index, record in
            DeviceRecord(
                id: "MOCK-RECORD-\(index + 1)",
                displayName: isChineseLocale ? record.zh : record.en,
                sourceType: "bonjour",
                host: "192.168.1.\(10 + index)",
                port: 54321,
                lastConnected: Date().addingTimeInterval(TimeInterval(-record.daysAgo * 86400)),
                connectionCount: record.count,
                connectionHistory: []
            )
        }
    }

    // MARK: - Mock Transfer Records

    /// Returns mock transfer history for the Transfer History view.
    var mockTransferRecords: [TransferRecord] {
        let records: [(fileName: String, size: Int64, hoursAgo: Int, direction: TransferRecord.Direction)] = [
            ("Vacation_Photos.zip", 125_000_000, 1, .received),
            ("Project_Report.pdf", 2_500_000, 3, .sent),
            ("Meeting_Notes.docx", 450_000, 6, .received),
            ("presentation.pptx", 8_700_000, 12, .sent),
            ("music_playlist.m3u", 15_000, 24, .received)
        ]

        return records.map { record in
            TransferRecord(
                fileName: record.fileName,
                fileSize: record.size,
                direction: record.direction,
                timestamp: Date().addingTimeInterval(TimeInterval(-record.hoursAgo * 3600)),
                success: true
            )
        }
    }

    // MARK: - Check if a peer ID is mock

    static func isMockPeer(_ peerID: String) -> Bool {
        peerID.hasPrefix("MOCK-PEER-") && peerID.hasSuffix("-SCREENSHOT")
    }
}
