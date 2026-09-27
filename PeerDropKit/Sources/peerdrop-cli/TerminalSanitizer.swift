import Foundation

/// Neutralises peer-controlled strings before they are printed to the
/// operator's terminal. The SAS "y" is the only step that grants a new peer
/// access to the wrapped shell, so a display name must not be able to move the
/// cursor, erase lines, or start new lines to forge or hide the SAS prompt.
enum TerminalSanitizer {
    /// Removes C0 controls (incl. ESC, CR, LF, TAB), DEL, C1 controls, the
    /// Unicode line/paragraph separators, and bidi embedding/override/isolate
    /// marks. All other (printable) Unicode is kept.
    static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !isDropped(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F:          // C0, DEL, C1
            return true
        case 0x2028, 0x2029:                    // line / paragraph separator
            return true
        case 0x200E, 0x200F, 0x061C,            // LRM, RLM, ALM
             0x202A...0x202E,                   // bidi embeddings / overrides
             0x2066...0x2069:                   // bidi isolates
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
