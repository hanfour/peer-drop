import XCTest
@testable import peerdrop_cli

final class TerminalSanitizerTests: XCTestCase {

    func test_plainAndUnicodeTextIsKept() {
        XCTAssertEqual(TerminalSanitizer.sanitize("Alice's iPhone 15"), "Alice's iPhone 15")
        XCTAssertEqual(TerminalSanitizer.sanitize("柏漢的 iPhone 🍎"), "柏漢的 iPhone 🍎")
    }

    func test_ansiEscapeIsNeutralised() {
        // ESC removed → the sequence can no longer move the cursor / recolour.
        let out = TerminalSanitizer.sanitize("evil\u{1B}[2K\u{1B}[1Aphone")
        XCTAssertFalse(out.unicodeScalars.contains("\u{1B}"))
        XCTAssertEqual(out, "evil[2K[1Aphone")
    }

    func test_newlinesAndCarriageReturnAreRemoved() {
        let out = TerminalSanitizer.sanitize("phone\nSAS: 1234 5678\r")
        XCTAssertFalse(out.contains("\n"))
        XCTAssertFalse(out.contains("\r"))
        XCTAssertEqual(out, "phoneSAS: 1234 5678")
    }

    func test_c0DelAndC1ControlsAreRemoved() {
        let raw = "a\u{00}b\u{07}c\u{08}d\u{7F}e\u{9B}f\u{85}g"
        XCTAssertEqual(TerminalSanitizer.sanitize(raw), "abcdefg")
    }

    func test_bidiOverridesAndLineSeparatorsAreRemoved() {
        let raw = "x\u{202E}y\u{2066}z\u{2028}w\u{2029}v"
        XCTAssertEqual(TerminalSanitizer.sanitize(raw), "xyzwv")
    }

    // MARK: - SAS prompt

    func test_localPairPrompt_sanitizesNameAndWarnsAboutShellAccess() {
        let lines = PairingPrompt.lines(
            displayName: "iPhone\n\u{1B}[1ASAS: 0000 0000",
            sas: "1234 5678",
            fingerprint: "ABCD",
            isRelay: false)
        let text = lines.joined(separator: "\n")
        XCTAssertFalse(text.unicodeScalars.contains("\u{1B}"))
        // The attacker's forged "SAS:" stays on the name line, not on its own line.
        XCTAssertEqual(lines.filter { $0.hasPrefix("SAS:") }, ["SAS: 1234 5678  (verify it matches the phone)"])
        XCTAssertTrue(text.lowercased().contains("shell"))
    }

    func test_relayPairPrompt_showsFingerprintWhenNoSAS() {
        let lines = PairingPrompt.lines(displayName: "Mac", sas: nil, fingerprint: "ABCD EF01", isRelay: true)
        XCTAssertTrue(lines.contains { $0.contains("ABCD EF01") })
        XCTAssertTrue(lines.joined().lowercased().contains("shell"))
    }
}
