import Foundation

/// Pure grouping logic for consecutive messages from the same sender.
/// Only the first message of a run shows avatar and name.
public enum ChatMessageRuns {
    public static let defaultGap: TimeInterval = 300

    private static func speakerKey(_ m: ChatMessage) -> String {
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
        var result = Set<String>()
        var previous: ChatMessage?
        for m in messages {
            if let p = previous {
                let newRun = speakerKey(m) != speakerKey(p)
                    || m.timestamp.timeIntervalSince(p.timestamp) > gap
                    || !calendar.isDate(m.timestamp, inSameDayAs: p.timestamp)
                if newRun { result.insert(m.id) }
            } else {
                result.insert(m.id)
            }
            previous = m
        }
        return result
    }

    /// `messages` must be sorted ascending by timestamp.
    /// IDs of messages that are the first of their calendar day.
    public static func dayStartIDs(
        in messages: [ChatMessage],
        calendar: Calendar = .current
    ) -> Set<String> {
        var result = Set<String>()
        var previous: ChatMessage?
        for m in messages {
            if let p = previous {
                if !calendar.isDate(m.timestamp, inSameDayAs: p.timestamp) { result.insert(m.id) }
            } else {
                result.insert(m.id)
            }
            previous = m
        }
        return result
    }
}
