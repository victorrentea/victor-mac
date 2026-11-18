import XCTest
@testable import VictorAddons

final class PowerPointFalseDirtyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let deck = "/Users/x/My Drive/Deck.pptx"

    private func sample(_ at: TimeInterval, saved: Bool, path: String? = nil, name: String = "Deck.pptx") -> PowerPointSample {
        PowerPointSample(at: t0.addingTimeInterval(at), deck: name, path: path ?? deck, slide: 1, slideID: 1,
                         presenting: false, frontmost: true, saved: saved)
    }

    func testClearsADeckUnsavedAtFirstSightAfterAColdStart() {
        var p = PowerPointFalseDirtyPolicy(started: t0)
        XCTAssertEqual(p.consume(sample(110, saved: false), appLaunched: t0.addingTimeInterval(100)), deck)
    }

    func testNeverClearsTwiceNorAnEditMadeLater() {
        var p = PowerPointFalseDirtyPolicy(started: t0)
        let launched = t0.addingTimeInterval(100)
        XCTAssertNil(p.consume(sample(110, saved: true), appLaunched: launched))
        XCTAssertNil(p.consume(sample(112, saved: false), appLaunched: launched), "an edit after first sight is real")
    }

    func testLeavesADeckAloneWhenPowerPointWasAlreadyRunning() {
        var p = PowerPointFalseDirtyPolicy(started: t0)
        XCTAssertNil(p.consume(sample(10, saved: false), appLaunched: t0.addingTimeInterval(-500)),
                     "Victor Addons restarted next to a deck with real edits")
        var q = PowerPointFalseDirtyPolicy(started: t0)
        XCTAssertNil(q.consume(sample(700, saved: false), appLaunched: t0.addingTimeInterval(100)),
                     "a second deck opened long after launch")
    }

    func testLeavesRecoveredAndNeverSavedDecksAlone() {
        var p = PowerPointFalseDirtyPolicy(started: t0)
        let launched = t0.addingTimeInterval(100)
        XCTAssertNil(p.consume(sample(110, saved: false, name: "Deck (Recovered)"), appLaunched: launched))
        XCTAssertNil(p.consume(sample(110, saved: false, path: "Presentation1"), appLaunched: launched))
    }

    func testANewPowerPointStartIsJudgedAgain() {
        var p = PowerPointFalseDirtyPolicy(started: t0)
        XCTAssertNil(p.consume(sample(110, saved: true), appLaunched: t0.addingTimeInterval(100)))
        XCTAssertNil(p.consume(.gone(at: t0.addingTimeInterval(200)), appLaunched: nil))
        XCTAssertEqual(p.consume(sample(310, saved: false), appLaunched: t0.addingTimeInterval(300)), deck)
    }
}
