import XCTest
@testable import VictorAddons

final class PasteNoticeTests: XCTestCase {
    func testOneLinePasteShowsSenderAndText() {
        XCTAssertEqual(PasteNotice.text(sender: "Alice", text: "hello"), "From Alice: hello")
    }

    func testMultiLinePasteShowsFirstLineAndHowManyMore() {
        XCTAssertEqual(PasteNotice.text(sender: "Bob", text: "\n  line one \nline two\n\nline three"),
                       "From Bob: line one (+2 lines)")
    }

    func testLongLineIsCut() {
        let t = PasteNotice.text(sender: "C", text: String(repeating: "x", count: 100))
        XCTAssertEqual(t, "From C: " + String(repeating: "x", count: 60) + "…")
    }

    func testCopiedPillIsMarked() {
        XCTAssertTrue(PasteNotice.text(sender: "A", text: "x", copied: true).hasPrefix("✅ From A: x"))
    }

    func testButtonLabels() {
        XCTAssertEqual(BannerAction.copyDismiss.title, "Copy & Dismiss")
        XCTAssertEqual(BannerAction.copySend.title, "Copy & Send to all")
    }
}
