import Foundation

/// Pure grouping logic for consecutive messages from the same sender.
/// Only the first message of a run shows avatar and name.
public enum ChatMessageRuns {
    public static let defaultGap: TimeInterval = 300

    static func speakerKey(_ m: ChatMessage) -> String {
        m.senderID ?? (m.isOutgoing ? "\u{0}me" : "\u{0}peer")
    }

    /// `messages` must be sorted ascending by timestamp.
    /// IDs of messages that start a new run: first message, speaker change,
    /// day change, or gap strictly greater than `gap` seconds.
    public static func firstInRunIDs(
        in messages: [ChatMessage],
        gap: TimeInterval = defaultGap,
        calendar: Calendar = .current
    ) -> Set<String> {
        runStarts(messages, id: \.id, speaker: speakerKey, date: \.timestamp, gap: gap, calendar: calendar)
    }

    /// `messages` must be sorted ascending by timestamp.
    /// IDs of messages that are the first of their calendar day.
    public static func dayStartIDs(
        in messages: [ChatMessage],
        calendar: Calendar = .current
    ) -> Set<String> {
        dayStarts(messages, id: \.id, date: \.timestamp, calendar: calendar)
    }

    /// Shared run rule (also used by `ThreadMerge` for mixed chat/note items).
    static func runStarts<T>(
        _ items: [T], id: (T) -> String, speaker: (T) -> String, date: (T) -> Date,
        gap: TimeInterval, calendar: Calendar
    ) -> Set<String> {
        var result = Set<String>()
        var previous: T?
        for m in items {
            if let p = previous {
                let newRun = speaker(m) != speaker(p)
                    || date(m).timeIntervalSince(date(p)) > gap
                    || !calendar.isDate(date(m), inSameDayAs: date(p))
                if newRun { result.insert(id(m)) }
            } else {
                result.insert(id(m))
            }
            previous = m
        }
        return result
    }

    static func dayStarts<T>(_ items: [T], id: (T) -> String, date: (T) -> Date, calendar: Calendar) -> Set<String> {
        var result = Set<String>()
        var previous: T?
        for m in items {
            if let p = previous {
                if !calendar.isDate(date(m), inSameDayAs: date(p)) { result.insert(id(m)) }
            } else {
                result.insert(id(m))
            }
            previous = m
        }
        return result
    }
}
