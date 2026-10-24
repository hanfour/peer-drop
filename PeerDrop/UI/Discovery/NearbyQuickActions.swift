import Foundation

/// Quick-entry buttons shown above the Nearby lists.
enum NearbyQuickAction: CaseIterable {
    case qr, manual, invite, scan

    /// Fixed order qr, manual, invite, scan. `invite` needs the relay feature; `scan` needs a real scanner.
    static func available(relayEnabled: Bool, hasScanner: Bool) -> [NearbyQuickAction] {
        allCases.filter { action in
            switch action {
            case .qr, .manual: return true
            case .invite: return relayEnabled
            case .scan: return hasScanner
            }
        }
    }
}
