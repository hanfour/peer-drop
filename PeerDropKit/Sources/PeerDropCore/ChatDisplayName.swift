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
}
