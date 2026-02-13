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

    private enum LocaleType {
        case english
        case chineseTraditional
        case chineseSimplified
        case japanese
        case korean
    }

    private var currentLocale: LocaleType {
        let lang = Locale.preferredLanguages.first ?? "en"
        if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-HK") {
            return .chineseTraditional
        } else if lang.hasPrefix("zh") {
            return .chineseSimplified
        } else if lang.hasPrefix("ja") {
            return .japanese
        } else if lang.hasPrefix("ko") {
            return .korean
        }
        return .english
    }

    private var isChineseLocale: Bool {
        currentLocale == .chineseTraditional || currentLocale == .chineseSimplified
    }

    // MARK: - Mock Peer IDs (stable for UI tests)

    static let mockPeerID1 = "MOCK-PEER-001-SCREENSHOT"
    static let mockPeerID2 = "MOCK-PEER-002-SCREENSHOT"
    static let mockPeerID3 = "MOCK-PEER-003-SCREENSHOT"
    static let mockPeerID4 = "MOCK-PEER-004-SCREENSHOT"
    static let mockConnectedPeerID = mockPeerID1

    // MARK: - Mock Discovered Peers

    /// Returns localized device name based on current locale.
    private func localizedName(_ names: (en: String, zhHant: String, zhHans: String, ja: String, ko: String)) -> String {
        switch currentLocale {
        case .english:
            return names.en
        case .chineseTraditional:
            return names.zhHant
        case .chineseSimplified:
            return names.zhHans
        case .japanese:
            return names.ja
        case .korean:
            return names.ko
        }
    }

    /// Returns 4 mock discovered peers for the Nearby tab.
    var mockDiscoveredPeers: [DiscoveredPeer] {
        let names: [(en: String, zhHant: String, zhHans: String, ja: String, ko: String)] = [
            ("Sarah's MacBook Pro", "小美的 MacBook Pro", "小美的 MacBook Pro", "さくらの MacBook Pro", "서연의 MacBook Pro"),
            ("James's iPhone", "阿傑的 iPhone", "阿杰的 iPhone", "健太の iPhone", "민준의 iPhone"),
            ("Emily's iPad", "小雯的 iPad", "小雯的 iPad", "美咲の iPad", "수빈의 iPad"),
            ("Dad's iPhone", "爸爸的 iPhone", "爸爸的 iPhone", "パパの iPhone", "아빠의 iPhone")
        ]

        return [
            DiscoveredPeer(
                id: Self.mockPeerID1,
                displayName: localizedName(names[0]),
                endpoint: .manual(host: "192.168.1.10", port: 54321),
                source: .bonjour,
                lastSeen: Date()
            ),
            DiscoveredPeer(
                id: Self.mockPeerID2,
                displayName: localizedName(names[1]),
                endpoint: .manual(host: "192.168.1.11", port: 54321),
                source: .bonjour,
                lastSeen: Date().addingTimeInterval(-60)
            ),
            DiscoveredPeer(
                id: Self.mockPeerID3,
                displayName: localizedName(names[2]),
                endpoint: .manual(host: "192.168.1.12", port: 54321),
                source: .bonjour,
                lastSeen: Date().addingTimeInterval(-120)
            ),
            DiscoveredPeer(
                id: Self.mockPeerID4,
                displayName: localizedName(names[3]),
                endpoint: .manual(host: "192.168.1.13", port: 54321),
                source: .bonjour,
                lastSeen: Date().addingTimeInterval(-180)
            )
        ]
    }

    // MARK: - Mock Connected Peer

    /// Returns a mock connected peer identity.
    var mockConnectedPeer: PeerIdentity {
        let names: (en: String, zhHant: String, zhHans: String, ja: String, ko: String) = (
            "Sarah's MacBook Pro",
            "小美的 MacBook Pro",
            "小美的 MacBook Pro",
            "さくらの MacBook Pro",
            "서연의 MacBook Pro"
        )
        return PeerIdentity(
            id: Self.mockConnectedPeerID,
            displayName: localizedName(names),
            certificateFingerprint: "MOCK-CERT-FINGERPRINT-123456"
        )
    }

    // MARK: - Mock Chat Messages

    /// Returns localized peer short name for chat.
    private var localizedPeerShortName: String {
        switch currentLocale {
        case .english:
            return "Sarah"
        case .chineseTraditional, .chineseSimplified:
            return "小美"
        case .japanese:
            return "さくら"
        case .korean:
            return "서연"
        }
    }

    /// Returns mock chat messages for the connected peer.
    var mockChatMessages: [ChatMessage] {
        let peerName = localizedPeerShortName
        let now = Date()

        let messages: [(text: String, isOutgoing: Bool, minutesAgo: Int)]

        switch currentLocale {
        case .english:
            messages = [
                ("Hey! Are you free?", false, 15),
                ("Yes, what's up?", true, 14),
                ("I want to share the vacation photos with you", false, 12),
                ("Sure! Let's use PeerDrop", true, 10),
                ("Sending now...", false, 5),
                ("Got them! Beautiful photos!", true, 3),
                ("Thanks! Let's hang out next time", false, 1)
            ]
        case .chineseTraditional:
            messages = [
                ("嗨！你有空嗎？", false, 15),
                ("有啊，怎麼了？", true, 14),
                ("我想把假期的照片傳給你看", false, 12),
                ("好啊！用 PeerDrop 傳吧", true, 10),
                ("正在傳送中...", false, 5),
                ("收到了！照片好美！", true, 3),
                ("謝謝！下次一起出去玩吧", false, 1)
            ]
        case .chineseSimplified:
            messages = [
                ("嗨！你有空吗？", false, 15),
                ("有啊，怎么了？", true, 14),
                ("我想把假期的照片传给你看", false, 12),
                ("好啊！用 PeerDrop 传吧", true, 10),
                ("正在传送中...", false, 5),
                ("收到了！照片好美！", true, 3),
                ("谢谢！下次一起出去玩吧", false, 1)
            ]
        case .japanese:
            messages = [
                ("ねえ！今ひま？", false, 15),
                ("うん、どうしたの？", true, 14),
                ("休暇の写真を送りたいんだ", false, 12),
                ("いいよ！PeerDropで送って", true, 10),
                ("今送ってるよ...", false, 5),
                ("届いた！すごくきれい！", true, 3),
                ("ありがとう！また遊ぼうね", false, 1)
            ]
        case .korean:
            messages = [
                ("안녕! 지금 시간 있어?", false, 15),
                ("응, 무슨 일이야?", true, 14),
                ("휴가 사진 보내주고 싶어서", false, 12),
                ("좋아! PeerDrop으로 보내줘", true, 10),
                ("지금 보내는 중...", false, 5),
                ("받았어! 사진 너무 예뻐!", true, 3),
                ("고마워! 다음에 또 놀자", false, 1)
            ]
        }

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
        let records: [(en: String, zhHant: String, zhHans: String, ja: String, ko: String, daysAgo: Int, count: Int)] = [
            ("Sarah's MacBook Pro", "小美的 MacBook Pro", "小美的 MacBook Pro", "さくらの MacBook Pro", "서연의 MacBook Pro", 0, 15),
            ("James's iPhone", "阿傑的 iPhone", "阿杰的 iPhone", "健太の iPhone", "민준의 iPhone", 1, 8),
            ("Emily's iPad", "小雯的 iPad", "小雯的 iPad", "美咲の iPad", "수빈의 iPad", 3, 5),
            ("Mom's iPhone", "媽媽的 iPhone", "妈妈的 iPhone", "ママの iPhone", "엄마의 iPhone", 7, 12),
            ("Office iMac", "辦公室 iMac", "办公室 iMac", "オフィスの iMac", "사무실 iMac", 14, 3)
        ]

        return records.enumerated().map { index, record in
            let name: String
            switch currentLocale {
            case .english:
                name = record.en
            case .chineseTraditional:
                name = record.zhHant
            case .chineseSimplified:
                name = record.zhHans
            case .japanese:
                name = record.ja
            case .korean:
                name = record.ko
            }

            return DeviceRecord(
                id: "MOCK-RECORD-\(index + 1)",
                displayName: name,
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
