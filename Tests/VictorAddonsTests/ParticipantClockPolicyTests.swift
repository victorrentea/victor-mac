import XCTest
@testable import VictorAddons

final class ParticipantClockPolicyTests: XCTestCase {
    let bucharest = TimeZone(identifier: "Europe/Bucharest")!
    let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    let athens = TimeZone(identifier: "Europe/Athens")!
    let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    // Thu 2026-11-19 13:05 in Bucharest (UTC+2).
    let noon = Date(timeIntervalSince1970: 1_795_086_300)

    func testNoCountryNoClock() {
        XCTAssertFalse(ParticipantClockPolicy.isShown(participants: nil, local: bucharest, at: noon))
    }
    func testSameOffsetNoClock() {
        XCTAssertFalse(ParticipantClockPolicy.isShown(participants: athens, local: bucharest, at: noon))
    }
    func testOtherOffsetShowsClock() {
        XCTAssertTrue(ParticipantClockPolicy.isShown(participants: lisbon, local: bucharest, at: noon))
    }
    func testLabelSameDay() {
        XCTAssertEqual(ParticipantClockPolicy.label(flag: "🇵🇹", participants: lisbon, local: bucharest, at: noon), "🇵🇹 11:05")
    }
    func testLabelHalfHourZone() {
        XCTAssertEqual(ParticipantClockPolicy.label(flag: "🇮🇳", participants: kolkata, local: bucharest, at: noon), "🇮🇳 16:35")
    }
    func testLabelOtherDayShowsWeekday() {
        let late = noon.addingTimeInterval(10 * 3600)   // 23:05 Bucharest → 02:35 Fri in Kolkata
        XCTAssertEqual(ParticipantClockPolicy.label(flag: "🇮🇳", participants: kolkata, local: bucharest, at: late), "🇮🇳 Fri 02:35")
    }
    func testTwelveHourMacDropsTheLeadingZero() {
        let afternoon = noon.addingTimeInterval(3 * 3600)   // 16:05 Bucharest → 14:05 Lisbon
        XCTAssertEqual(ParticipantClockPolicy.label(flag: "🇵🇹", participants: lisbon, local: bucharest, at: afternoon,
                                                    timeFormat: "h:mm"), "🇵🇹 2:05")
    }
}
