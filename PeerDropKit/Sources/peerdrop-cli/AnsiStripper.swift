import Foundation

/// Strips ANSI CSI/OSC escape sequences from terminal output so chat-mode
/// messages are plain text. Terminal-faithful mode (Phase 2) bypasses this.
enum AnsiStripper {
    // CSI: ESC [ ... final-byte (@ through ~). OSC: ESC ] ... (BEL or ESC \).
    private static let pattern =
        "\u{1B}\\[[0-9;?]*[ -/]*[@-~]" +      // CSI
        "|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)" + // OSC ... BEL/ST
        "|\u{1B}[@-Z\\\\-_]"                  // 2-byte ESC sequences

    private static let regex = try! NSRegularExpression(pattern: pattern)

    static func strip(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
