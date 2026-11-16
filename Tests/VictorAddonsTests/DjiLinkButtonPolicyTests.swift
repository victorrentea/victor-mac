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
        XCTAssertFalse(DjiLinkButtonPolicy.accepts(now: t.addingTimeInterval(0.05), last: t))
        XCTAssertTrue(DjiLinkButtonPolicy.accepts(now: t.addingTimeInterval(0.4), last: t))
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
