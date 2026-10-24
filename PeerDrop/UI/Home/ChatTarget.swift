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
        query: String,
        name: (DeviceRecord) -> String = { $0.displayName }
    ) -> (connected: [DeviceRecord], friends: [DeviceRecord]) {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let kept = needle.isEmpty ? records : records.filter { fold(name($0)).contains(needle) }
        let sorted = kept.sorted {
            let c = name($0).localizedCaseInsensitiveCompare(name($1))
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
        var connected: [DeviceRecord] = []
        var friends: [DeviceRecord] = []
        for r in sorted {
            if presence(r) == .online { connected.append(r) } else { friends.append(r) }
        }
        return (connected, friends)
    }

    fileprivate static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension HomeListLogic {
    /// The filled "Connect" pill only makes sense for a nearby friend that is not already mid-connection.
    static func showsConnectPill(presence: PeerPresence, isConnecting: Bool) -> Bool {
        presence == .nearby && !isConnecting
    }
}

// MARK: - Categories (Project F1)

extension HomeListLogic {
    /// One row of the 分類 section: the category and every friend record in it (any presence), sorted by name.
    struct CategorySection: Identifiable, Equatable {
        let category: FriendCategory
        let members: [DeviceRecord]
        var id: String { category.id }
        var count: Int { members.count }
    }

    /// Home sections in display order: 已連線 → 分類 → 朋友 (uncategorized only).
    struct HomeSections {
        /// Every online friend matching the query, categorized or not.
        let connected: [DeviceRecord]
        /// Categories in store order; without a query all of them (empty ones too).
        let categories: [CategorySection]
        /// Not-online friends that are in no category. While searching, matching not-online friends that ARE
        /// in a category are listed here too (sorted with the rest), so search always finds a friend.
        let friends: [DeviceRecord]
        /// `record.id → category name` for the categorized friends listed in `friends` (search only), shown as
        /// a caption on their row. Empty without a query.
        var friendCategoryNames: [String: String] = [:]
    }

    /// `record.id → category id` for every record that is in a category. A record counts as a member when
    /// ANY of its aliases (`aliases(record)`, e.g. the friend's other records) is listed in a category, so two
    /// records of the same person always land in the same category. First category (store order) wins.
    static func categoryIDs(for records: [DeviceRecord], categories: [FriendCategory],
                            aliases: (DeviceRecord) -> [String]) -> [String: String] {
        guard !categories.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for r in records {
            let ids = Set(aliases(r) + [r.id])
            if let c = categories.first(where: { !ids.isDisjoint(with: $0.friendIDs) }) { out[r.id] = c.id }
        }
        return out
    }

    /// Splits records into 已連線 / 分類 / 朋友. A connected friend shows in 已連線 AND still counts in its category.
    /// A non-empty `query` keeps categories whose name, or any member's name, matches; the count stays the
    /// whole category. Records whose `categoryID` names no existing category count as uncategorized.
    static func homeSections(
        records: [DeviceRecord],
        presence: (DeviceRecord) -> PeerPresence,
        query: String,
        name: (DeviceRecord) -> String = { $0.displayName },
        categories: [FriendCategory],
        categoryID: (DeviceRecord) -> String?
    ) -> HomeSections {
        let known = Set(categories.map(\.id))
        let base = sections(records: records, presence: presence, query: query, name: name)
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let friends: [DeviceRecord]
        var friendCategoryNames: [String: String] = [:]
        if needle.isEmpty {
            friends = base.friends.filter { categoryID($0).map { !known.contains($0) } ?? true }
        } else {
            friends = base.friends          // every matching not-online friend, categorized or not
            let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            for r in friends { if let id = categoryID(r), let n = names[id] { friendCategoryNames[r.id] = n } }
        }

        let sortedAll = records.sorted {
            let c = name($0).localizedCaseInsensitiveCompare(name($1))
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
        var membersByCategory: [String: [DeviceRecord]] = [:]
        for r in sortedAll {
            if let id = categoryID(r), known.contains(id) { membersByCategory[id, default: []].append(r) }
        }
        let ordered = categories.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        let cats: [CategorySection] = ordered.compactMap { c in
            let members = membersByCategory[c.id] ?? []
            if !needle.isEmpty, !fold(c.name).contains(needle), !members.contains(where: { fold(name($0)).contains(needle) }) {
                return nil
            }
            return CategorySection(category: c, members: members)
        }
        return HomeSections(connected: base.connected, categories: cats, friends: friends,
                            friendCategoryNames: friendCategoryNames)
    }

    /// Same rule the store enforces (trimmed 1–20 characters), so the UI can disable the save button.
    static func isValidCategoryName(_ raw: String) -> Bool {
        FriendCategoryStore.validName(raw) != nil
    }
}

/// What Return does in an inline category-name field: a valid name (trimmed 1–20) is created; an empty
/// field cancels; anything else (blank spaces, too long) keeps the field open with the text for editing.
enum InlineNameSubmit: Equatable {
    case create(String)
    case keepEditing
    case cancel

    static func decide(text: String) -> InlineNameSubmit {
        if let name = FriendCategoryStore.validName(text) { return .create(name) }
        return text.isEmpty ? .cancel : .keepEditing
    }
}

extension FriendCategoryStore {
    /// Moves a PERSON (every record id in `person`) to `categoryID` (nil = uncategorized): their other records
    /// are taken out of any category first, then `record` is assigned, so one person is never in two categories.
    func move(person: [String], record: String, to categoryID: String?) {
        let others = Set(person).subtracting([record])
        for id in others where category(containingAnyOf: [id]) != nil { assign(friendID: id, to: nil) }
        assign(friendID: record, to: categoryID)
    }
}

/// Second line of a Home row.
enum FriendSubtitle {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func text(presence: PeerPresence, lastConnected: Date, connectionCount: Int, source: String, isConnecting: Bool = false, now: Date = Date()) -> String {
        if isConnecting && presence != .online { return String(localized: "Connecting...") }
        switch presence {
        case .online:
            return source == "relay"
                ? String(localized: "Connected · Relay")
                : String(localized: "Connected · Local network")
        case .nearby:
            return String(localized: "Nearby · ready to connect")
        case .connecting:
            return String(localized: "Connecting...")
        case .offline:
            guard connectionCount > 0 else { return String(localized: "Not connected yet") }
            return String(format: String(localized: "Last online %@"), relativeFormatter.localizedString(for: lastConnected, relativeTo: now))
        }
    }
}
