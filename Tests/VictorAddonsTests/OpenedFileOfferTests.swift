import XCTest
@testable import VictorAddons

/// 📄 A file reaches the daemon only through a pill, and only when the daemon
/// will list it (2026-11-27).
final class OpenedFileOfferTests: XCTestCase {
    private let id = "https://github.com/o/r|a.py"

    func testAFirstOpenAsksTheDaemon() {
        XCTAssertEqual(OpenedFileOffer.action(identity: id, sessionActive: true, inFlight: false, verdict: nil), .ask)
    }

    func testASentFileIsRefreshedSilentlyAndADismissedOneNeverLeaves() {
        XCTAssertEqual(OpenedFileOffer.action(identity: id, sessionActive: true, inFlight: false, verdict: .sent), .pushSilently)
        XCTAssertEqual(OpenedFileOffer.action(identity: id, sessionActive: true, inFlight: false, verdict: .dismissed), .ignore)
    }

    func testNoSessionNoFileOrAPillUpSayNothing() {
        XCTAssertEqual(OpenedFileOffer.action(identity: id, sessionActive: false, inFlight: false, verdict: .sent), .ignore)
        XCTAssertEqual(OpenedFileOffer.action(identity: nil, sessionActive: true, inFlight: false, verdict: nil), .ignore)
        XCTAssertEqual(OpenedFileOffer.action(identity: id, sessionActive: true, inFlight: true, verdict: nil), .ignore)
    }

    func testNotListedNeverPushesAndAnUnansweredCheckIsDropped() {
        var asked: [String] = [], pushed: [String] = []
        let offer = OpenedFileOffer(ask: { reqId, _, _ in asked.append(reqId) },
                                    push: { _, _, f in pushed.append(f) }, screens: { [] })
        let file = "test-\(UUID().uuidString).py"   // no stored verdict
        offer.fileOpened(url: "https://github.com/o/r", branch: "main", file: file, sessionActive: true, icon: nil)
        XCTAssertEqual(asked.count, 1)
        offer.fileOpened(url: "https://github.com/o/r", branch: "main", file: file, sessionActive: true, icon: nil)
        XCTAssertEqual(asked.count, 1, "the same file again while asked: wait")
        offer.checkAnswered(id: asked[0], listed: false)
        XCTAssertEqual(pushed, [])
        offer.checkAnswered(id: "stranger", listed: true)
        XCTAssertEqual(pushed, [])
    }

    func testVerdictsExpireWithTheBannerLog() {
        let key = "test|\(UUID().uuidString)"
        let then = Date(timeIntervalSinceNow: -OpenedFileBannerLog.repeatAfter - 10)
        OpenedFileOffer.store(.dismissed, for: key, now: then)
        XCTAssertNil(OpenedFileOffer.verdict(for: key))
        OpenedFileOffer.store(.sent, for: key)
        XCTAssertEqual(OpenedFileOffer.verdict(for: key), .sent)
    }
}
