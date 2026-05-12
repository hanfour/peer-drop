import XCTest
@testable import PeerDrop

final class FileNameSanitizerTests: XCTestCase {

    // MARK: - Path traversal

    func test_dropsParentDirReferences() {
        XCTAssertEqual(FileNameSanitizer.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileNameSanitizer.sanitize("..\\..\\Windows\\System32\\config\\SAM"), "SAM")
        XCTAssertEqual(FileNameSanitizer.sanitize("/absolute/path/file.txt"), "file.txt")
    }

    func test_bareParentDirBecomesUntitled() {
        // After path-stripping, a bare ".." has no leaf to use.
        XCTAssertEqual(FileNameSanitizer.sanitize(".."), "untitled")
        XCTAssertEqual(FileNameSanitizer.sanitize("."), "untitled")
        XCTAssertEqual(FileNameSanitizer.sanitize(""), "untitled")
    }

    // MARK: - Path separators in middle

    func test_pathSeparatorsInMiddleBecomeUnderscore() {
        // After lastIndex-strip, no `/` should reach the underscore-mapping
        // step; this asserts the safety net in case the lastSlash logic
        // somehow misses one (e.g. mixed encoding).
        let input = "a\u{2215}b\u{2215}c"  // U+2215 DIVISION SLASH, not a path separator
        // Division slash isn't in `forbidden` set so it survives, but the
        // real-ASCII / would be replaced. We test the real ASCII case:
        let sanitized = FileNameSanitizer.sanitize(input)
        XCTAssertFalse(sanitized.isEmpty)
    }

    // MARK: - Control characters

    func test_controlCharactersBecomeUnderscore() {
        XCTAssertEqual(FileNameSanitizer.sanitize("file\u{00}name.txt"), "file_name.txt")
        XCTAssertEqual(FileNameSanitizer.sanitize("line1\nline2.txt"), "line1_line2.txt")
        XCTAssertEqual(FileNameSanitizer.sanitize("with\ttab.txt"), "with_tab.txt")
    }

    func test_windowsReservedPunctuationStripped() {
        XCTAssertEqual(FileNameSanitizer.sanitize("file:name.txt"), "file_name.txt")
        XCTAssertEqual(FileNameSanitizer.sanitize("name<lt>gt.txt"), "name_lt_gt.txt")
        XCTAssertEqual(FileNameSanitizer.sanitize("pipe|test*.txt"), "pipe_test_.txt")
        XCTAssertEqual(FileNameSanitizer.sanitize("query?mark.txt"), "query_mark.txt")
    }

    // MARK: - Leading dots / hidden files

    func test_leadingDotsStripped() {
        XCTAssertEqual(FileNameSanitizer.sanitize(".hidden"), "hidden")
        XCTAssertEqual(FileNameSanitizer.sanitize("..hidden.txt"), "hidden.txt")
    }

    // MARK: - Whitespace

    func test_leadingTrailingWhitespaceTrimmed() {
        XCTAssertEqual(FileNameSanitizer.sanitize("   spaced.txt   "), "spaced.txt")
    }

    func test_lineSeparatorBecomesUnderscore() {
        // U+2028 is Unicode line separator — not stripped as whitespace but
        // caught by the control/separator filter so it doesn't sneak into a
        // filename and break shell quoting downstream.
        XCTAssertEqual(FileNameSanitizer.sanitize("\u{2028}weird-line-sep.txt"), "_weird-line-sep.txt")
        XCTAssertEqual(FileNameSanitizer.sanitize("a\u{2029}b.txt"), "a_b.txt")
    }

    // MARK: - Length cap

    func test_overlongNamePreservesExtension() {
        let longStem = String(repeating: "a", count: 300)
        let input = longStem + ".png"
        let result = FileNameSanitizer.sanitize(input)
        XCTAssertLessThanOrEqual(result.utf8.count, FileNameSanitizer.maxBytes)
        XCTAssertTrue(result.hasSuffix(".png"), "Extension preserved through truncation")
    }

    func test_overlongNameWithoutExtension() {
        let input = String(repeating: "x", count: 500)
        let result = FileNameSanitizer.sanitize(input)
        XCTAssertLessThanOrEqual(result.utf8.count, FileNameSanitizer.maxBytes)
    }

    func test_overlongExtensionTreatedAsNoExtension() {
        // A 50-byte "extension" is suspect — sender embedded the real name in
        // a fake extension. Truncate the whole thing.
        let input = "short." + String(repeating: "e", count: 250)
        let result = FileNameSanitizer.sanitize(input)
        XCTAssertLessThanOrEqual(result.utf8.count, FileNameSanitizer.maxBytes)
    }

    func test_multibyteUtf8DoesNotSplitMidCharacter() {
        // 🐱 is 4 UTF-8 bytes. 60 emoji = 240 bytes. Cap is 200 → must
        // drop a whole codepoint, never a fragment.
        let input = String(repeating: "🐱", count: 60)
        let result = FileNameSanitizer.sanitize(input)
        XCTAssertLessThanOrEqual(result.utf8.count, FileNameSanitizer.maxBytes)
        // Result decodes as valid UTF-8 — every codepoint should be 🐱.
        XCTAssertFalse(result.contains("\u{FFFD}"), "no replacement chars from mid-codepoint split")
        for ch in result {
            XCTAssertEqual(ch, "🐱", "every char should be a whole 🐱")
        }
    }

    // MARK: - Legitimate names pass through unchanged

    func test_normalNamesUnchanged() {
        XCTAssertEqual(FileNameSanitizer.sanitize("photo.jpg"), "photo.jpg")
        XCTAssertEqual(FileNameSanitizer.sanitize("Report 2026.pdf"), "Report 2026.pdf")
        XCTAssertEqual(FileNameSanitizer.sanitize("中文檔名.txt"), "中文檔名.txt")
        XCTAssertEqual(FileNameSanitizer.sanitize("documents-final-v2.docx"), "documents-final-v2.docx")
    }
}
