import Foundation

/// Neutralises peer-controlled strings before they are printed to the
/// operator's terminal. The SAS "y" is the only step that grants a new peer
/// access to the wrapped shell, so a display name must not be able to move the
/// cursor, erase lines, or start new lines to forge or hide the SAS prompt.
enum TerminalSanitizer {
    /// Longest name we print, in Characters (an ellipsis is appended beyond).
    static let maxLength = 64

    /// Drops invisible / control / layout-changing scalars, collapses any
    /// whitespace run to one space, trims, and caps the result at `maxLength`
    /// characters (+ "…"). Printable Unicode (CJK, emoji, accents) is kept.
    static func sanitize(_ s: String, maxLength: Int = TerminalSanitizer.maxLength) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in s.unicodeScalars where !isDropped(scalar) {
            if scalar.properties.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(scalar)
        }
        let result = String(out)
        guard result.count > maxLength else { return result }
        return String(result.prefix(maxLength)) + "…"
    }

    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control,              // Cc: C0, DEL, C1 (ESC, CR, LF, TAB, …)
             .format,               // Cf: ZW(N)J/ZWSP, word joiner, BOM, soft hyphen,
                                    //     bidi marks/overrides/isolates, tags, U+180E
             .lineSeparator,        // Zl: U+2028
             .paragraphSeparator:   // Zp: U+2029
            return true
        default:
            break
        }
        switch scalar.value {
        case 0xFE00...0xFE0F, 0xE0100...0xE01EF:        // variation selectors
            return true
        case 0x3164, 0x115F, 0x1160, 0xFFA0:            // Hangul blank fillers
            return true
        default:
            return false
        }
    }
}

/// Text of the one-time pairing prompt. Pure so it can be unit-tested.
enum PairingPrompt {
    static func lines(displayName: String, sas: String?, fingerprint: String, isRelay: Bool) -> [String] {
        let name = TerminalSanitizer.sanitize(displayName)
        var lines = ["", "Pair with \"\(name)\"\(isRelay ? " (relay)" : "")?"]
        if let sas {
            lines.append("SAS: \(sas)  (verify it matches the phone)")
        } else {
            lines.append("Verify this fingerprint matches the phone:")
            lines.append("  \(fingerprint)")
        }
        lines.append("⚠️  Approving gives this device shell access: it can type commands into the wrapped session on this machine.")
        return lines
    }
}
