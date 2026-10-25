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

    /// Line and page breaks and tabs (`\n`, `\r`, `\t`, VT, FF, NEL, U+2028, U+2029) become
    /// one space each (a `\r\n` pair counts once). Other control characters (Cc) and
    /// format characters (Cf — bidi overrides/isolates, LRM/RLM, zero-width space, BOM…)
    /// are removed, except ZWJ/ZWNJ and emoji tag characters, which emoji sequences and
    /// some scripts need. Then surrounding whitespace is trimmed. Empty → nil. Does not
    /// truncate; the caller compares `count` against `maxStatusMessageLength`.
    nonisolated public static func cleanStatusMessage(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        var afterCR = false
        for scalar in raw.unicodeScalars {
            if scalar == "\n" && afterCR { afterCR = false; continue }
            afterCR = scalar == "\r"
            if isFoldedToSpace(scalar) {
                scalars.append(" ")
            } else if !isStrippedControl(scalar) {
                scalars.append(scalar)
            }
        }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    nonisolated private static func isFoldedToSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    nonisolated private static func isStrippedControl(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .control:
            return true
        case .format:
            // ZWNJ/ZWJ (emoji sequences, Persian/Indic text) and tag characters
            // (subdivision flags such as 🏴󠁧󠁢󠁳󠁣󠁴󠁿) stay.
            if s.value == 0x200C || s.value == 0x200D { return false }
            if (0xE0020...0xE007F).contains(s.value) { return false }
            return true
        default:
            return false
        }
    }

    nonisolated private static func category(for aliases: [String], in categories: [FriendCategory]) -> FriendCategory? {
        let wanted = Set(aliases)
        return categories.first { !wanted.isDisjoint(with: $0.friendIDs) }
    }
}
