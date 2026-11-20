import XCTest
@testable import VictorAddons

final class BottomLeftStackPolicyTests: XCTestCase {
    private typealias P = BottomLeftStackPolicy

    func testFirstPillTakesTheBottomSlot() {
        let r = P.arrive("a", into: [])
        XCTAssertEqual(r.order, ["a"])
        XCTAssertEqual(r.evicted, [])
    }

    func testSecondPillEntersBelowAndPushesTheFirstUp() {
        let r = P.arrive("b", into: ["a"])
        XCTAssertEqual(r.order, ["b", "a"], "bottom first: the newcomer at the bottom")
        XCTAssertEqual(r.evicted, [])
    }

    func testThirdPillStillFits() {
        let r = P.arrive("c", into: ["b", "a"])
        XCTAssertEqual(r.order, ["c", "b", "a"])
        XCTAssertEqual(r.evicted, [])
    }

    func testFourthPillPushesTheTopOneOut() {
        let r = P.arrive("d", into: ["c", "b", "a"])
        XCTAssertEqual(r.order, ["d", "c", "b"], "never more than three up")
        XCTAssertEqual(r.evicted, ["a"], "the oldest, on top, leaves")
    }

    func testAPillAlreadyUpThatArrivesAgainMovesToTheBottomWithoutDuplicating() {
        let r = P.arrive("a", into: ["b", "a"])
        XCTAssertEqual(r.order, ["a", "b"])
        XCTAssertEqual(r.evicted, [])
    }

    func testAPinnedAlarmOnTopStaysAndTheOldestUnpinnedLeavesInstead() {
        let r = P.arrive("d", into: ["c", "b", "alarm"], pinned: { $0 == "alarm" })
        XCTAssertEqual(r.order, ["d", "c", "alarm"])
        XCTAssertEqual(r.evicted, ["b"])
    }

    func testThreePinnedAlarmsLetTheStackGrowRatherThanLoseOne() {
        let r = P.arrive("c", into: ["a1", "a2", "a3"], pinned: { $0.hasPrefix("a") })
        XCTAssertEqual(r.order, ["c", "a1", "a2", "a3"])
        XCTAssertEqual(r.evicted, [])
    }

    func testThePinnedNewcomerIsNeverTheOnePushedOut() {
        let r = P.arrive("new", into: ["c", "b", "a"], pinned: { _ in true })
        XCTAssertEqual(r.order, ["new", "c", "b", "a"])
    }

    func testLeavingTheBottomLetsTheTopDrop() {
        XCTAssertEqual(P.leave("b", from: ["b", "a"]), ["a"])
        XCTAssertEqual(P.leave("x", from: ["b", "a"]), ["b", "a"])
    }

    func testSlotHeights() {
        XCTAssertEqual(P.lift(slot: 0, boxHeight: 63), 0, "the bottom slot is flush with the edge, as before")
        XCTAssertEqual(P.lift(slot: 1, boxHeight: 63), 63 + P.gap)
    }
}
