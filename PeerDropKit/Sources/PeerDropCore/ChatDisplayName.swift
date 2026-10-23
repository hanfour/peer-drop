import Foundation

/// Pure display-name cleanup for chat bubbles and headers.
/// Localized fallbacks (e.g. "對方", "這個群組") live in the View layer,
/// because this module has no localization.
public enum ChatDisplayName {
    /// Name without surrounding whitespace/newlines, or `nil` when the input
    /// is `nil` or blank. Never truncates; truncation is a display concern.
    public static func trimmed(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The first candidate that is not blank (trimmed), or nil if all are.
    /// Chat uses it as `preferred(liveName, storedName)`: a peer's identity is
    /// fixed at handshake, so a message's stored name can be old or blank while
    /// the live connection knows the current one.
    public static func preferred(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let name = trimmed(candidate) { return name }
        }
        return nil
    }

    /// Name for a saved record. A relay placeholder (`relay-<code>`) or blank stored name defers to the
    /// live connection's name when there is one; otherwise the stored name wins.
    public static func forRecord(recordName: String, liveName: String?) -> String {
        let stored = trimmed(recordName)
        if stored == nil || stored!.hasPrefix("relay-") {
            return preferred(liveName, recordName) ?? recordName
        }
        return stored!
    }
}
