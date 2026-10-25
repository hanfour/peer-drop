import Foundation

/// Pure rules for category presence ("am I reachable to this friend right now")
/// and the per-category status message. No state, no clock: callers pass the
/// instant and calendar so tests and time-zone changes are deterministic.
public enum PresencePolicy {
    public static let maxStatusMessageLength = 60

    /// Whether `date` falls inside the window. Half-open `[start, end)`; `start > end`
    /// wraps past midnight and the weekday is the one the window *started* on.
    /// An invalid window is treated as "inside" (fail closed: the friend sees us offline).
    nonisolated public static func isInWindow(_ w: ScheduleWindow, at date: Date, calendar: Calendar) -> Bool {
        guard w.isValid else { return true }
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday else { return true }
        let m = hour * 60 + minute
        func inDays(_ d: Int) -> Bool { w.weekdays.isEmpty || w.weekdays.contains(d) }
        if w.startMinute < w.endMinute {
            return inDays(weekday) && w.startMinute <= m && m < w.endMinute
        }
        let previousWeekday = (weekday + 5) % 7 + 1
        return (inDays(weekday) && m >= w.startMinute) || (inDays(previousWeekday) && m < w.endMinute)
    }

    /// Whether a friend (all of their `aliases`) may see us online. Uncategorized
    /// friends and `.online` categories are visible; `.scheduled` hides us *inside* the window.
    nonisolated public static func isVisible(aliases: [String], categories: [FriendCategory], at date: Date, calendar: Calendar) -> Bool {
        guard let category = category(for: aliases, in: categories) else { return true }
        switch category.presence {
        case .online: return true
        case .offline: return false
        case .scheduled(let w): return !isInWindow(w, at: date, calendar: calendar)
        }
    }

    /// Earliest start/end boundary of any scheduled category after `date`, or nil if none.
    /// Ignores weekdays on purpose: an extra wake-up is harmless because callers recompute.
    nonisolated public static func nextTransition(categories: [FriendCategory], after date: Date, calendar: Calendar) -> Date? {
        var earliest: Date?
        for category in categories {
            guard case .scheduled(let w) = category.presence else { continue }
            for minute in [w.startMinute, w.endMinute] {
                let components = DateComponents(hour: minute / 60, minute: minute % 60)
                guard let next = calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime) else { continue }
                if earliest.map({ next < $0 }) ?? true { earliest = next }
            }
        }
        return earliest
    }

    /// The status message a friend should see, or nil when there is none, it is
    /// switched off, or the friend is uncategorized.
    nonisolated public static func statusText(aliases: [String], categories: [FriendCategory]) -> String? {
        guard let category = category(for: aliases, in: categories),
              category.showStatusMessage,
              let text = category.statusMessage, !text.isEmpty else { return nil }
        return text
    }

    /// Newlines (`\n`, `\r`, U+2028) become one space each (a `\r\n` pair counts once),
    /// then surrounding whitespace is trimmed. Empty → nil. Does not truncate; the
    /// caller compares `count` against `maxStatusMessageLength`.
    nonisolated public static func cleanStatusMessage(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "\r\n", with: " ")
        for newline in ["\n", "\r", "\u{2028}"] {
            text = text.replacingOccurrences(of: newline, with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    nonisolated private static func category(for aliases: [String], in categories: [FriendCategory]) -> FriendCategory? {
        let wanted = Set(aliases)
        return categories.first { !wanted.isDisjoint(with: $0.friendIDs) }
    }
}
