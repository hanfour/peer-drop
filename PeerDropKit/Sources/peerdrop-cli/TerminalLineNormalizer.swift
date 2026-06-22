import Foundation

/// Applies a minimal terminal-line model to text whose ANSI escape sequences
/// have already been removed (by `AnsiStripper`). It interprets the C0
/// cursor-control bytes that stripping leaves behind — backspace (`\u{08}`),
/// carriage return (`\r`) and newline (`\n`) — so that line-editor redraws and
/// prompt repaints collapse to the text a human would actually see on a
/// terminal, instead of leaking artifacts.
///
/// Concretely, an interactive zsh echoing `echo hi` emits `e\u{08}echo hi`
/// (type `e`, backspace, repaint `echo hi`). Without applying the backspace
/// that renders as `eecho hi`; applying it yields `echo hi`. Likewise the
/// prompt is repainted with `\r`-anchored overwrites that, once applied,
/// collapse to a single clean prompt line.
///
/// This is deliberately NOT a full terminal emulator: there is no scrollback
/// grid and no cursor addressing (those escapes are removed upstream). It
/// models a single logical line with an overwrite cursor — enough to clean up
/// the output of a line-based program for chat display.
///
/// Known limitation: it does not model erase-to-EOL (`ESC[K`, which AnsiStripper
/// removes before this runs), so a program that repaints a SHORTER line via
/// `\r` + new text + `ESC[K` will leave the old tail behind. The clean-shell
/// launch path (`ShellLauncher`) avoids this because zsh repaints by padding
/// the full width with spaces; an arbitrary wrapped program may not.
enum TerminalLineNormalizer {
    static func normalize(_ s: String) -> String {
        var lines: [String] = []
        var line: [Character] = []
        var cursor = 0

        for ch in s {
            switch ch {
            case "\n", "\r\n":
                // Swift clusters CRLF into a single Character; treat it (and a
                // lone LF) as an end-of-line. A CR before the LF would only
                // reset the cursor, which ending the line discards anyway.
                lines.append(trimTrailing(line))
                line.removeAll(keepingCapacity: true)
                cursor = 0
            case "\r":
                cursor = 0
            case "\u{08}", "\u{7F}":              // backspace / delete
                if cursor > 0 { cursor -= 1 }
            case "\t":
                put(ch, &line, &cursor)          // keep tabs literal
            default:
                // Drop any remaining lone C0 control characters (BEL, VT, …);
                // anything printable (incl. multi-scalar graphemes) is written.
                if ch.unicodeScalars.allSatisfy({ $0.value < 0x20 }) { continue }
                put(ch, &line, &cursor)
            }
        }
        if !line.isEmpty { lines.append(trimTrailing(line)) }

        // Drop trailing blank lines left by prompt repaints so the emitted
        // message doesn't end in dangling whitespace.
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func put(_ ch: Character, _ line: inout [Character], _ cursor: inout Int) {
        if cursor < line.count { line[cursor] = ch } else { line.append(ch) }
        cursor += 1
    }

    private static func trimTrailing(_ chars: [Character]) -> String {
        var end = chars.count
        while end > 0, chars[end - 1] == " " { end -= 1 }
        return String(chars[0..<end])
    }
}
