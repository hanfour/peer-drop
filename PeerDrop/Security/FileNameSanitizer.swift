import Foundation

/// Sanitizes filenames received from untrusted peers before they enter any
/// filesystem path operation.
///
/// `FileManager`'s `appendingPathComponent` does NOT defend against:
///   - Path traversal: `"../../etc/passwd"` resolves above the intended dir
///   - Absolute paths: `"/var/log/...".`  ignored as a component but still
///     surprising when it appears in the receiver's UI
///   - Reserved on shared storage: empty string, `.`, `..`, NUL bytes
///   - Excessive length: APFS allows ~255 byte filenames but downstream
///     systems (CloudKit, iCloud Drive sync) reject earlier
///   - Control characters: NULL, newline, tab in filenames break terminal
///     output and some Finder behaviors
///
/// This utility produces a safe basename — never a path. Callers are still
/// responsible for using `appendingPathComponent` on the sanitized string,
/// never string interpolation.
enum FileNameSanitizer {

    /// Maximum filename length in bytes (UTF-8). APFS allows 255 bytes; we
    /// cap lower so we have room for `UUID().uuidString.prefix(8)` prefixes
    /// (9 bytes) and `" (N).ext"` collision suffixes (~10 bytes) without
    /// overflowing.
    static let maxBytes = 200

    /// Sanitize a filename from an untrusted peer. Returns a basename
    /// suitable for use with `appendingPathComponent`. Never returns a
    /// string containing `/`, `\`, NUL, or control characters; never
    /// returns `""`, `"."`, or `".."`.
    ///
    /// The function is intentionally lossy — when in doubt, replace
    /// rather than reject. Rejection blocks legitimate-but-unusual names
    /// (emoji-only filenames, RTL text, etc.); replacement keeps the
    /// transfer flowing and surfaces a usable-if-different name to the
    /// user.
    static func sanitize(_ raw: String) -> String {
        // 1. Strip any directory traversal: drop everything up to and
        //    including the last forward or back slash. PixelLab and many
        //    other senders include the original path; we want only the
        //    leaf.
        var name = raw
        if let lastSlash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: lastSlash)...])
        }

        // 2. Reject reserved leaf names that would resolve to the parent
        //    or current directory. After path-stripping these can only
        //    appear as the entire input.
        if name.isEmpty || name == "." || name == ".." {
            return "untitled"
        }

        // 3. Map control characters (NUL, newline, tab, etc.), reserved
        //    filename punctuation, and path separators to underscore.
        //    The Unicode `Cc` and `Cf` categories cover the standard
        //    control set; we add the path-relevant ASCII punctuation
        //    explicitly.
        let forbidden: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|", "\0"]
        name = String(name.map { ch -> Character in
            if forbidden.contains(ch) { return "_" }
            if let scalar = ch.unicodeScalars.first {
                switch scalar.properties.generalCategory {
                case .control,         // Cc — TAB, NUL, etc.
                     .format,          // Cf — zero-width chars, BOM
                     .lineSeparator,   // Zl — U+2028
                     .paragraphSeparator: // Zp — U+2029
                    return "_"
                default: break
                }
            }
            return ch
        })

        // 4. Strip leading dots — files starting with `.` are hidden on
        //    Unix-like systems and some receivers treat them as
        //    "configuration files" rather than user-visible content. A
        //    sneaky peer might use this to hide the file from the user
        //    after delivery.
        while name.hasPrefix(".") {
            name = String(name.dropFirst())
        }

        // 5. Strip leading/trailing whitespace — Finder strips trailing
        //    spaces in display, leading-space names sort weirdly.
        name = name.trimmingCharacters(in: .whitespaces)

        // 6. After all stripping, the string may now be empty. Use a
        //    deterministic placeholder; the caller's deduplication logic
        //    will append " (N)" if there's a collision.
        if name.isEmpty {
            return "untitled"
        }

        // 7. Length cap. Preserve the extension if doing so doesn't
        //    overflow on its own (a `.someridiculouslylongextension`
        //    longer than 16 bytes is treated as not-an-extension and the
        //    whole name gets truncated wholesale).
        if name.utf8.count > maxBytes {
            let parts = name.components(separatedBy: ".")
            if parts.count >= 2, let ext = parts.last, ext.utf8.count < 16 {
                let stem = parts.dropLast().joined(separator: ".")
                let extWithDot = "." + ext
                let stemBudget = maxBytes - extWithDot.utf8.count
                name = truncateToBytes(stem, max: stemBudget) + extWithDot
            } else {
                name = truncateToBytes(name, max: maxBytes)
            }
        }

        return name
    }

    /// Truncate a string so its UTF-8 byte count is ≤ max. Drops trailing
    /// codepoints rather than splitting in the middle of a multi-byte
    /// character.
    private static func truncateToBytes(_ s: String, max: Int) -> String {
        var result = ""
        var bytes = 0
        for ch in s {
            let chBytes = String(ch).utf8.count
            if bytes + chBytes > max { break }
            result.append(ch)
            bytes += chBytes
        }
        return result
    }
}
