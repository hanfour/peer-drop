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

    // MARK: - Review 2, item 5

    func test_formatCharactersAreRemoved() {
        // ZWSP, ZWNJ, ZWJ, WORD JOINER, BOM, SOFT HYPHEN, MONGOLIAN VS, TAG chars
        let raw = "a\u{200B}b\u{200C}c\u{200D}d\u{2060}e\u{FEFF}f\u{00AD}g\u{180E}h\u{E0041}\u{E007F}i"
        XCTAssertEqual(TerminalSanitizer.sanitize(raw), "abcdefghi")
    }

    func test_variationSelectorsAreRemoved() {
        XCTAssertEqual(TerminalSanitizer.sanitize("a\u{FE00}b\u{FE0F}c\u{E0100}d\u{E01EF}e"), "abcde")
    }

    func test_blankLookingFillersAreRemoved() {
        XCTAssertEqual(TerminalSanitizer.sanitize("a\u{3164}b\u{115F}c\u{1160}d\u{FFA0}e"), "abcde")
    }

    func test_whitespaceRunsCollapse_andEndsAreTrimmed() {
        XCTAssertEqual(TerminalSanitizer.sanitize("  my \u{00A0}\u{2003}\u{3000}  phone  "), "my phone")
    }

    func test_longNameIsCappedAt64Characters() {
        let out = TerminalSanitizer.sanitize(String(repeating: "A", count: 200))
        XCTAssertEqual(out, String(repeating: "A", count: 64) + "…")
    }

    func test_nameExactly64Characters_isNotTruncated() {
        let name = String(repeating: "B", count: 64)
        XCTAssertEqual(TerminalSanitizer.sanitize(name), name)
    }

    /// A 200-char padded name used to push a fake "SAS:" onto what looks like
    /// its own terminal line by soft-wrapping.
    func test_paddedNameLineWrapSpoof_isNeutralised() throws {
        let spoofs = [
            "iPhone" + String(repeating: " ", count: 200) + "SAS: 000 000",
            "iPhone" + String(repeating: "\u{3164}", count: 200) + "SAS: 000 000",
            "iPhone" + String(repeating: "\u{2800}", count: 0) + String(repeating: "\u{200B}", count: 200) + "SAS: 000 000",
        ]
        for raw in spoofs {
            let out = TerminalSanitizer.sanitize(raw)
            XCTAssertLessThanOrEqual(out.count, 65, out)
            XCTAssertFalse(out.contains("  "), out)
            let lines = PairingPrompt.lines(displayName: raw, sas: "123 456", fingerprint: "F", isRelay: false)
            let nameLine = try XCTUnwrap(lines.first { $0.hasPrefix("Device name:") })
            XCTAssertLessThan(nameLine.count, 100, "the name line must not be long enough to wrap: \(nameLine)")
        }
    }

    // MARK: - Final review, item 5

    func test_combiningMarks_cappedAtTwoPerGrapheme() {
        XCTAssertEqual(TerminalSanitizer.sanitize("e\u{0301}\u{0302}\u{0303}\u{0304}x"), "e\u{0301}\u{0302}x")
        XCTAssertEqual(TerminalSanitizer.sanitize("a\u{20DD}\u{20DE}\u{20DF}"), "a\u{20DD}\u{20DE}")   // Me
    }

    func test_zalgoInput_isBounded() {
        let zalgo = String(repeating: "Z" + String(repeating: "\u{0336}\u{0301}", count: 25), count: 200)
        let out = TerminalSanitizer.sanitize(zalgo)
        XCTAssertLessThanOrEqual(out.unicodeScalars.count, TerminalSanitizer.maxScalars + 1)
        XCTAssertLessThanOrEqual(out.count, TerminalSanitizer.maxLength + 1)
        XCTAssertTrue(out.hasSuffix("…"))
    }

    func test_scalarCap_appliesBeforeCharacterCap() {
        // 60 characters of 3 scalars each = 180 scalars (under the 64-char cap).
        let out = TerminalSanitizer.sanitize(String(repeating: "e\u{0301}\u{0302}", count: 60))
        XCTAssertLessThanOrEqual(out.unicodeScalars.count, TerminalSanitizer.maxScalars + 1)
        XCTAssertTrue(out.hasSuffix("…"))
    }

    func test_prompt_nameLineComesAfterSASAndFingerprintLines() throws {
        let lines = PairingPrompt.lines(
            displayName: "iPhone", sas: "123 456", fingerprint: "F", isRelay: false,
            peerKeyFingerprint: "1111 2222 3333 4444 5555", ownFingerprint: "AAAA BBBB CCCC DDDD EEEE")
        let nameIdx = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("Device name:") })
        let sasIdx = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("SAS:") })
        let peerFpIdx = try XCTUnwrap(lines.firstIndex { $0.contains("1111 2222 3333 4444 5555") })
        let ownFpIdx = try XCTUnwrap(lines.firstIndex { $0.contains("AAAA BBBB CCCC DDDD EEEE") })
        XCTAssertGreaterThan(nameIdx, sasIdx)
        XCTAssertGreaterThan(nameIdx, peerFpIdx)
        XCTAssertGreaterThan(nameIdx, ownFpIdx)
        XCTAssertFalse(lines[..<nameIdx].joined().contains("iPhone"), "name must not appear above the SAS/fingerprints")
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
