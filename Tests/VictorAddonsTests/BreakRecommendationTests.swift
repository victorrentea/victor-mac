import XCTest
@testable import VictorAddons

final class BreakRecommendationTests: XCTestCase {
    private func rec(_ minutes: Double?) -> Int? {
        BreakRecommendation.minutes(sinceBreakEnded: minutes.map { $0 * 60 })
    }

    func testUnderAnHourIsTenMinutes() {
        XCTAssertEqual(rec(0), 10)
        XCTAssertEqual(rec(59.9), 10)
    }

    func testUpToAnHourAndAHalfIsTwelve() {
        XCTAssertEqual(rec(60), 12)
        XCTAssertEqual(rec(90), 12)
    }

    func testMoreThanAnHourAndAHalfIsFifteen() {
        XCTAssertEqual(rec(90.1), 15)
        XCTAssertEqual(rec(4 * 60), 15)
    }

    func testNoFingerWithoutARecentBreak() {
        XCTAssertNil(rec(nil))
        XCTAssertNil(rec(13 * 60))
        XCTAssertNil(rec(-1))
    }
}
