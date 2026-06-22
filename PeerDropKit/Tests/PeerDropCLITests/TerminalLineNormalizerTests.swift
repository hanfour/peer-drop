import XCTest
@testable import peerdrop_cli

final class TerminalLineNormalizerTests: XCTestCase {
    func test_appliesBackspace_collapsesZleDoubledChar() {
        // zsh ZLE echoes 'e', backspaces, repaints 'echo hi'.
        XCTAssertEqual(TerminalLineNormalizer.normalize("e\u{08}echo hi"), "echo hi")
    }

    func test_carriageReturnOverwritesFromLineStart() {
        // A '%' partial-line marker overwritten by the real prompt via CR.
        XCTAssertEqual(TerminalLineNormalizer.normalize("%   \rhi"), "hi")
    }

    func test_newlineSplitsLines_andTrimsTrailingBlanks() {
        XCTAssertEqual(TerminalLineNormalizer.normalize("a\nb\n\n\n"), "a\nb")
    }

    func test_dropsLoneControlChars() {
        XCTAssertEqual(TerminalLineNormalizer.normalize("hi\u{07}there"), "hithere")
    }

    func test_plainOutputPassesThrough_minusTrailingNewline() {
        XCTAssertEqual(TerminalLineNormalizer.normalize("hi\n"), "hi")
        XCTAssertEqual(TerminalLineNormalizer.normalize("line1\nline2"), "line1\nline2")
    }

    func test_realInteractiveZshEchoResponse_collapsesToCleanTranscript() {
        // The exact byte shape captured from interactive zsh answering `echo hi`,
        // after AnsiStripper has removed the CSI/OSC sequences.
        let stripped = "e\u{08}echo hi\r\nhi\n%"
            + String(repeating: " ", count: 79)
            + "\r \r\rhanfourmini@host PeerDropKit % "
        XCTAssertEqual(
            TerminalLineNormalizer.normalize(stripped),
            "echo hi\nhi\nhanfourmini@host PeerDropKit %"
        )
    }
}
