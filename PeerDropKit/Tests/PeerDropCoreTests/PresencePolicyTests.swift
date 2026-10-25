import XCTest
@testable import PeerDropCore

final class PresencePolicyTests: XCTestCase {
    private func cal(_ tz: String = "Asia/Taipei") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, tz: String = "Asia/Taipei") -> Date {
        let c = cal(tz)
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // 2026-10-22 Thu(5), 23 Fri(6), 24 Sat(7), 25 Sun(1), 26 Mon(2)
    private func oct(_ day: Int, _ h: Int, _ mi: Int) -> Date { date(2026, 10, day, h, mi) }

    func testWindowTable() {
        struct Row {
            let weekdays: Set<Int>, start: Int, end: Int, at: Date, expected: Bool, label: String
        }
        let rows: [Row] = [
            Row(weekdays: [], start: 540, end: 1020, at: oct(23, 9, 0), expected: true, label: "same-day 09:00"),
            Row(weekdays: [], start: 540, end: 1020, at: oct(23, 16, 59), expected: true, label: "same-day 16:59"),
            Row(weekdays: [], start: 540, end: 1020, at: oct(23, 17, 0), expected: false, label: "same-day 17:00 (exclusive end)"),
            Row(weekdays: [], start: 540, end: 1020, at: oct(23, 8, 59), expected: false, label: "same-day 08:59"),
            Row(weekdays: [6], start: 1320, end: 420, at: oct(23, 22, 0), expected: true, label: "Fri 22:00 start"),
            Row(weekdays: [6], start: 1320, end: 420, at: oct(24, 6, 59), expected: true, label: "Sat 06:59 tail"),
            Row(weekdays: [6], start: 1320, end: 420, at: oct(24, 7, 0), expected: false, label: "Sat 07:00 end"),
            Row(weekdays: [6], start: 1320, end: 420, at: oct(24, 22, 0), expected: false, label: "Sat 22:00 not an allowed day"),
            Row(weekdays: [6], start: 1320, end: 420, at: oct(22, 23, 0), expected: false, label: "Thu 23:00"),
            Row(weekdays: [6], start: 1320, end: 420, at: oct(23, 6, 0), expected: false, label: "Fri 06:00 belongs to Thu's window"),
            Row(weekdays: [], start: 1380, end: 60, at: oct(23, 23, 30), expected: true, label: "daily 23:30"),
            Row(weekdays: [], start: 1380, end: 60, at: oct(24, 0, 30), expected: true, label: "daily 00:30"),
            Row(weekdays: [], start: 1380, end: 60, at: oct(24, 1, 0), expected: false, label: "daily 01:00"),
            Row(weekdays: [1, 7], start: 0, end: 1439, at: oct(24, 12, 0), expected: true, label: "Sat noon on weekend"),
            Row(weekdays: [1, 7], start: 0, end: 1439, at: oct(26, 12, 0), expected: false, label: "Mon noon on weekend"),
            // Invalid windows fail closed: always "inside" (= offline).
            Row(weekdays: [], start: 600, end: 600, at: oct(23, 12, 0), expected: true, label: "start == end"),
            Row(weekdays: [0], start: 540, end: 1020, at: oct(23, 3, 0), expected: true, label: "weekday 0"),
            Row(weekdays: [], start: 1440, end: 60, at: oct(23, 3, 0), expected: true, label: "startMinute 1440"),
        ]
        for r in rows {
            let w = ScheduleWindow(weekdays: r.weekdays, startMinute: r.start, endMinute: r.end)
            XCTAssertEqual(PresencePolicy.isInWindow(w, at: r.at, calendar: cal()), r.expected, r.label)
        }
    }

    func testWindowRespectsCalendarTimeZone() {
        let w = ScheduleWindow(weekdays: [], startMinute: 540, endMinute: 1020)
        let instant = date(2026, 10, 23, 12, 0)  // 12:00 Taipei = 21:00 previous day in Los Angeles
        XCTAssertTrue(PresencePolicy.isInWindow(w, at: instant, calendar: cal("Asia/Taipei")))
        XCTAssertFalse(PresencePolicy.isInWindow(w, at: instant, calendar: cal("America/Los_Angeles")))
    }

    func testWindowAcrossDaylightSavingGap() {
        // 2026-03-08 in New York: 02:00-03:00 does not exist.
        let w = ScheduleWindow(weekdays: [], startMinute: 150, endMinute: 200)
        let at = date(2026, 3, 8, 3, 0, tz: "America/New_York")
        XCTAssertTrue(PresencePolicy.isInWindow(w, at: at, calendar: cal("America/New_York")))
    }

    func testIsVisibleRules() {
        let c = cal()
        let window = ScheduleWindow(weekdays: [], startMinute: 540, endMinute: 1020)
        let inside = oct(23, 10, 0), outside = oct(23, 20, 0)
        let cats = [
            FriendCategory(id: "on", name: "on", friendIDs: ["a"], presence: .online),
            FriendCategory(id: "off", name: "off", friendIDs: ["b", "b2"], presence: .offline),
            FriendCategory(id: "sch", name: "sch", friendIDs: ["c"], presence: .scheduled(window)),
        ]
        XCTAssertTrue(PresencePolicy.isVisible(aliases: ["zzz"], categories: cats, at: inside, calendar: c), "uncategorized")
        XCTAssertTrue(PresencePolicy.isVisible(aliases: ["a"], categories: cats, at: inside, calendar: c), "online")
        XCTAssertFalse(PresencePolicy.isVisible(aliases: ["b"], categories: cats, at: inside, calendar: c), "offline")
        XCTAssertFalse(PresencePolicy.isVisible(aliases: ["c"], categories: cats, at: inside, calendar: c), "scheduled: inside window = hidden")
        XCTAssertTrue(PresencePolicy.isVisible(aliases: ["c"], categories: cats, at: outside, calendar: c), "scheduled: outside window = visible")
        XCTAssertTrue(PresencePolicy.isVisible(aliases: [], categories: cats, at: inside, calendar: c), "no aliases")
        XCTAssertFalse(PresencePolicy.isVisible(aliases: ["x", "b2"], categories: cats, at: inside, calendar: c), "second alias hits")
    }

    func testNextTransitionPicksEarliestStartOrEndAndNilWithoutSchedules() {
        let c = cal()
        let sched = FriendCategory(name: "s", presence: .scheduled(ScheduleWindow(weekdays: [6], startMinute: 1320, endMinute: 420)))
        XCTAssertEqual(PresencePolicy.nextTransition(categories: [sched], after: oct(23, 21, 0), calendar: c), oct(23, 22, 0))
        XCTAssertEqual(PresencePolicy.nextTransition(categories: [sched], after: oct(23, 23, 0), calendar: c), oct(24, 7, 0))
        let off = FriendCategory(name: "o", presence: .offline)
        XCTAssertNil(PresencePolicy.nextTransition(categories: [off], after: oct(23, 21, 0), calendar: c))
        XCTAssertNil(PresencePolicy.nextTransition(categories: [], after: oct(23, 21, 0), calendar: c))
    }

    func testStatusMessageValidation() {
        XCTAssertEqual(PresencePolicy.cleanStatusMessage("  a\nb  "), "a b")
        XCTAssertEqual(PresencePolicy.cleanStatusMessage("a\r\nb\u{2028}c"), "a b c")
        XCTAssertNil(PresencePolicy.cleanStatusMessage("   "))
        XCTAssertNil(PresencePolicy.cleanStatusMessage(""))
        let family = String(repeating: "👨‍👩‍👧", count: 60)
        XCTAssertEqual(PresencePolicy.cleanStatusMessage(family)?.count, 60)
        XCTAssertEqual(PresencePolicy.maxStatusMessageLength, 60)
    }

    func testStatusMessageFoldsBreaksAndStripsControls() {
        let table: [(String, String?, String)] = [
            ("a\u{2029}b", "a b", "paragraph separator"),
            ("a\u{85}b", "a b", "NEL"),
            ("a\u{0B}b\u{0C}c", "a b c", "VT and FF"),
            ("a\tb", "a b", "tab"),
            ("a\r\n\r\nb", "a  b", "each CRLF pair counts once"),
            ("\u{202E}evil\u{202C}", "evil", "RLO/PDF overrides"),
            ("\u{2066}x\u{2069}\u{2067}y\u{2069}\u{2068}z\u{2069}", "xyz", "isolates"),
            ("\u{202A}a\u{202B}b\u{202D}c", "abc", "LRE/RLE/LRO"),
            ("a\u{200E}b\u{200F}c", "abc", "LRM/RLM"),
            ("a\u{200B}b\u{FEFF}c\u{00AD}d", "abcd", "ZWSP, BOM, soft hyphen"),
            ("a\u{0}b\u{7}c\u{1B}d\u{7F}e\u{9F}f", "abcdef", "C0/C1 controls and DEL"),
            ("\u{202E}\u{200B}  ", nil, "only controls → nil"),
            ("👨\u{200D}👩\u{200D}👧", "👨\u{200D}👩\u{200D}👧", "ZWJ kept"),
            ("می\u{200C}خواهم", "می\u{200C}خواهم", "ZWNJ kept"),
            ("🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
             "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}", "tag sequence flag kept"),
            ("1\u{FE0F}\u{20E3}", "1\u{FE0F}\u{20E3}", "keycap kept"),
        ]
        for (raw, expected, label) in table {
            XCTAssertEqual(PresencePolicy.cleanStatusMessage(raw), expected, label)
        }
        XCTAssertEqual(PresencePolicy.cleanStatusMessage("👨\u{200D}👩\u{200D}👧")?.count, 1)
        XCTAssertEqual(PresencePolicy.cleanStatusMessage("🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}")?.count, 1)
    }

    func testStatusTextHonoursShowFlagAndUncategorized() {
        let cats = [
            FriendCategory(id: "1", name: "shown", friendIDs: ["a"], statusMessage: "hi", showStatusMessage: true),
            FriendCategory(id: "2", name: "hidden", friendIDs: ["b"], statusMessage: "secret", showStatusMessage: false),
            FriendCategory(id: "3", name: "empty", friendIDs: ["c"], statusMessage: nil, showStatusMessage: true),
        ]
        XCTAssertEqual(PresencePolicy.statusText(aliases: ["a"], categories: cats), "hi")
        XCTAssertNil(PresencePolicy.statusText(aliases: ["b"], categories: cats))
        XCTAssertNil(PresencePolicy.statusText(aliases: ["c"], categories: cats))
        XCTAssertNil(PresencePolicy.statusText(aliases: ["zzz"], categories: cats))
    }
}
