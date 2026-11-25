import XCTest
@testable import VictorAddons

final class DjiUnplugWatchTests: XCTestCase {
    private var raised: [Date] = []
    private var resumed = 0

    private func watch() -> DjiUnplugWatch {
        DjiUnplugWatch(raise: { [unowned self] in self.raised.append($0) },
                       resume: { [unowned self] in self.resumed += 1 })
    }

    func testLiveReceiverFallingOffUsbRaises() {
        let w = watch()
        w.gateChanged(.linked)
        w.gateChanged(.absent)
        XCTAssertEqual(raised.count, 1)
        XCTAssertTrue(w.isRaised)
    }

    func testReceiverWithNoTxUnpluggedStaysQuiet() {
        let w = watch()
        w.gateChanged(.linked)
        w.gateChanged(.noTx)     // the red link-lost alarm's case
        w.gateChanged(.absent)
        XCTAssertTrue(raised.isEmpty)
    }

    func testAppStartingWithoutReceiverStaysQuiet() {
        let w = watch()
        w.gateChanged(.absent)
        XCTAssertTrue(raised.isEmpty)
    }

    func testReplugWithTxTakesItDownOnce() {
        let w = watch()
        w.gateChanged(.linked)
        w.gateChanged(.absent)
        w.gateChanged(.linked)
        XCTAssertEqual(resumed, 1)
        XCTAssertFalse(w.isRaised)
        w.gateChanged(.noTx)
        w.gateChanged(.linked)   // an ordinary TX blip is not ours to resume
        XCTAssertEqual(resumed, 1)
    }

    func testTextSaysWhenAndWhatToDo() {
        let t = DjiUnplugWatch.text(since: Date())
        XCTAssertTrue(t.contains("off USB") && t.contains("replug"))
    }
}
