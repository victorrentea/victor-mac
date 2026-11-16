import XCTest
@testable import VictorAddons

final class DjiLinkButtonPolicyTests: XCTestCase {

    /// The two reports one press produced on the real receiver (2026-11-16):
    /// `page=12 usage=233 value=1`, then `value=0` a millisecond later.
    func testThePressIsTheKeyGoingDownOnly() {
        XCTAssertTrue(DjiLinkButtonPolicy.isPress(usagePage: 12, usage: 233, value: 1))
        XCTAssertFalse(DjiLinkButtonPolicy.isPress(usagePage: 12, usage: 233, value: 0))
    }

    func testOtherUsagesAreNotTheLinkButton() {
        XCTAssertFalse(DjiLinkButtonPolicy.isPress(usagePage: 12, usage: 234, value: 1))   // volume down
        XCTAssertFalse(DjiLinkButtonPolicy.isPress(usagePage: 1, usage: 233, value: 1))
    }

    func testABouncingSwitchIsOnePress() {
        let t = Date()
        XCTAssertEqual(DjiLinkButtonPolicy.onPress(now: t.addingTimeInterval(0.01), last: t, waitingForSecond: true), .bounce)
    }

    /// 2026-11-16: two presses toggle ChatGPT's voice, one mutes.
    func testASecondPressInsideTheWindowMakesADouble() {
        let t = Date()
        XCTAssertEqual(DjiLinkButtonPolicy.onPress(now: t.addingTimeInterval(0.2), last: t, waitingForSecond: true), .second)
        XCTAssertEqual(DjiLinkButtonPolicy.onPress(now: t.addingTimeInterval(0.39), last: t, waitingForSecond: true), .second)
    }

    func testAPressAfterTheWindowOrWithNothingWaitingIsAFirst() {
        let t = Date()
        XCTAssertEqual(DjiLinkButtonPolicy.onPress(now: t.addingTimeInterval(0.6), last: t, waitingForSecond: true), .first)
        XCTAssertEqual(DjiLinkButtonPolicy.onPress(now: t.addingTimeInterval(0.2), last: t, waitingForSecond: false), .first,
                       "after a double, the next press starts over")
        XCTAssertEqual(DjiLinkButtonPolicy.onPress(now: t, last: .distantPast, waitingForSecond: false), .first)
    }

    func testTheMicrophoneIsStruckThroughOnlyWhenMuted() {
        XCTAssertEqual(DjiLinkButtonPolicy.symbol(muted: true), "mic.slash.fill")
        XCTAssertEqual(DjiLinkButtonPolicy.symbol(muted: false), "mic.fill")
    }

    func testTheStruckThroughMicrophoneStaysWhileMuted() {
        XCTAssertFalse(DjiLinkButtonPolicy.fadesOut(muted: true))
        XCTAssertTrue(DjiLinkButtonPolicy.fadesOut(muted: false))
    }
}
