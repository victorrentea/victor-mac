import XCTest
@testable import VictorAddons

final class UntilBreakCountdownTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testTitleIsCoffeeAndMinutesWithoutLeadingZero() {
        XCTAssertEqual(UntilBreakCountdown.title(remaining: 600), "☕ 10:00")
        XCTAssertEqual(UntilBreakCountdown.title(remaining: 582), "☕ 9:42")
        XCTAssertEqual(UntilBreakCountdown.title(remaining: 5), "☕ 0:05")
        XCTAssertEqual(UntilBreakCountdown.title(remaining: -3), "☕ 0:00")
    }

    /// Rounded up: the slot never reads 0:00 while there is still time left.
    func testRemainingRoundsUpAndClampsAtZero() {
        XCTAssertEqual(UntilBreakCountdown.remaining(deadline: t0 + 59.2, now: t0), 60)
        XCTAssertEqual(UntilBreakCountdown.remaining(deadline: t0 + 0.1, now: t0), 1)
        XCTAssertEqual(UntilBreakCountdown.remaining(deadline: t0 - 30, now: t0), 0)
        XCTAssertEqual(UntilBreakCountdown.remaining(deadline: nil, now: t0), 0)
    }
}
