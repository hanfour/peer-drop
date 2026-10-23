import Foundation
import PeerDropCore

/// Navigation value for pushing a chat from the Home list.
struct ChatTarget: Hashable {
    let peerID: String
    let name: String
}

/// Pure list logic for the Home tab (kept free of SwiftUI so it can be unit tested).
enum HomeListLogic {
    /// Splits records into 已連線 (presence == online) and 朋友 (everything else), each sorted by name.
    /// A non-empty `query` keeps only records whose name contains it (case- and width-insensitive).
    static func sections(
        records: [DeviceRecord],
        presence: (DeviceRecord) -> PeerPresence,
        query: String
    ) -> (connected: [DeviceRecord], friends: [DeviceRecord]) {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let kept = needle.isEmpty ? records : records.filter { fold($0.displayName).contains(needle) }
        let sorted = kept.sorted {
            let c = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
        var connected: [DeviceRecord] = []
        var friends: [DeviceRecord] = []
        for r in sorted {
            if presence(r) == .online { connected.append(r) } else { friends.append(r) }
        }
        return (connected, friends)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Second line of a Home row.
enum FriendSubtitle {
    static func text(presence: PeerPresence, lastConnected: Date, connectionCount: Int, source: String, now: Date = Date()) -> String {
        switch presence {
        case .online:
            return source == "relay"
                ? String(localized: "Connected · Relay")
                : String(localized: "Connected · Local network")
        case .nearby:
            return String(localized: "Nearby · ready to connect")
        case .offline:
            guard connectionCount > 0 else { return String(localized: "Not connected yet") }
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return String(format: String(localized: "Last online %@"), f.localizedString(for: lastConnected, relativeTo: now))
        }
    }
}
