import Foundation

/// When a category counts as "reachable". F2 consumes this; F1 only stores it.
public struct ScheduleWindow: Codable, Equatable {
    public var weekdays: Set<Int>
    public var startMinute: Int
    public var endMinute: Int

    public init(weekdays: Set<Int>, startMinute: Int, endMinute: Int) {
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// Weekdays within 1...7, minutes within 0...1439, and a non-empty span
    /// (`start == end` is ambiguous, so it is rejected).
    public var isValid: Bool {
        weekdays.isSubset(of: Set(1...7))
            && (0...1439).contains(startMinute)
            && (0...1439).contains(endMinute)
            && startMinute != endMinute
    }
}

public enum CategoryPresence: Codable, Equatable {
    case online
    case offline
    case scheduled(ScheduleWindow)
}

public struct FriendCategory: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public var order: Int
    public var friendIDs: [String]
    public var notificationsEnabled: Bool
    public var presence: CategoryPresence
    public var statusMessage: String?
    public var showStatusMessage: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        order: Int = 0,
        friendIDs: [String] = [],
        notificationsEnabled: Bool = true,
        presence: CategoryPresence = .online,
        statusMessage: String? = nil,
        showStatusMessage: Bool = true
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.friendIDs = friendIDs
        self.notificationsEnabled = notificationsEnabled
        self.presence = presence
        self.statusMessage = statusMessage
        self.showStatusMessage = showStatusMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, order, friendIDs, notificationsEnabled, presence, statusMessage, showStatusMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        friendIDs = try c.decodeIfPresent([String].self, forKey: .friendIDs) ?? []
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        presence = try c.decodeIfPresent(CategoryPresence.self, forKey: .presence) ?? .online
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
        showStatusMessage = try c.decodeIfPresent(Bool.self, forKey: .showStatusMessage) ?? true
    }
}
