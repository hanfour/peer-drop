import Foundation

/// Neutralises peer-controlled strings before they are printed to the
/// operator's terminal. The SAS "y" is the only step that grants a new peer
/// access to the wrapped shell, so a display name must not be able to move the
/// cursor, erase lines, or start new lines to forge or hide the SAS prompt.
enum TerminalSanitizer {
    /// Longest name we print, in Characters (an ellipsis is appended beyond).
    static let maxLength = 64
    /// Longest name we print, in Unicode scalars (bounds Zalgo-style stacks).
    static let maxScalars = 128
    /// Combining marks (Mn/Me) kept per grapheme; the rest are dropped.
    static let maxMarksPerGrapheme = 2

    /// Drops invisible / control / layout-changing scalars, keeps at most
    /// `maxMarksPerGrapheme` combining marks per character, collapses any
    /// whitespace run to one space, trims, and caps the result at `maxLength`
    /// characters and `maxScalars` scalars (+ "…" when cut). Printable
    /// Unicode (CJK, emoji, accents) is kept.
    static func sanitize(_ s: String, maxLength: Int = TerminalSanitizer.maxLength) -> String {
        var filtered = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in s.unicodeScalars where !isDropped(scalar) {
            if scalar.properties.isWhitespace {
                pendingSpace = !filtered.isEmpty
                continue
            }
            if pendingSpace { filtered.append(" "); pendingSpace = false }
            filtered.append(scalar)
        }

        var out = ""
        var characters = 0
        var scalars = 0
        for character in String(filtered) {
            var kept = String.UnicodeScalarView()
            var marks = 0
            for scalar in character.unicodeScalars {
                if isCombiningMark(scalar) {
                    marks += 1
                    if marks > maxMarksPerGrapheme { continue }
                }
                kept.append(scalar)
            }
            guard characters < maxLength, scalars + kept.count <= maxScalars else {
                return out + "…"
            }
            out.unicodeScalars.append(contentsOf: kept)
            characters += 1
            scalars += kept.count
        }
        return out
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: return true
        default: return false
        }
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
///
/// The peer-controlled name is printed LAST, on its own line, after the SAS
/// and fingerprint lines, so a long or wrapping name cannot forge a line
/// above them.
enum PairingPrompt {
    /// - Parameters:
    ///   - fingerprint: relay path only — the sender key fingerprint to compare.
    ///   - peerKeyFingerprint: phone-format fingerprint of the key the peer
    ///     actually used in the handshake (#173 mitigation).
    ///   - ownFingerprint: this CLI's phone-format fingerprint, as the phone's
    ///     pairing sheet shows it.
    static func lines(
        displayName: String, sas: String?, fingerprint: String, isRelay: Bool,
        peerKeyFingerprint: String? = nil, ownFingerprint: String? = nil
    ) -> [String] {
        var lines = ["", isRelay ? "A new device wants to pair (relay):" : "A new device wants to pair:"]
        if let sas {
            lines.append("SAS: \(sas)  (verify it matches the phone)")
            if let peerKeyFingerprint {
                lines.append("On the phone, open Security (the shield screen) and check that its own fingerprint equals: "
                             + "\(peerKeyFingerprint). The 6-digit code alone can be forged.")
            } else {
                lines.append("(this device's key fingerprint is unavailable — the 6-digit code alone can be forged; be extra careful)")
            }
            if let ownFingerprint {
                lines.append("The phone's pairing sheet should show: \(ownFingerprint)")
            }
        } else {
            lines.append("Verify this fingerprint matches the phone:")
            lines.append("  \(fingerprint)")
        }
        lines.append("⚠️  Approving gives this device shell access: it can type commands into the wrapped session on this machine.")
        lines.append("Device name: \"\(TerminalSanitizer.sanitize(displayName))\"")
        return lines
    }
}
