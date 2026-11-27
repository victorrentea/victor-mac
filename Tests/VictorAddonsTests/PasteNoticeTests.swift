import XCTest
@testable import VictorAddons

final class PasteNoticeTests: XCTestCase {
    func testOneLinePasteShowsSenderAndText() {
        XCTAssertEqual(PasteNotice.text(sender: "Alice", text: "hello"), "📋 Alice: hello")
    }

    func testMultiLinePasteShowsFirstLineAndHowManyMore() {
        XCTAssertEqual(PasteNotice.text(sender: "Bob", text: "\n  line one \nline two\n\nline three"),
                       "📋 Bob: line one (+2 lines)")
    }

    func testLongLineIsCut() {
        let t = PasteNotice.text(sender: "C", text: String(repeating: "x", count: 100))
        XCTAssertEqual(t, "📋 C: " + String(repeating: "x", count: 60) + "…")
    }

    func testCopiedPillIsMarked() {
        XCTAssertTrue(PasteNotice.text(sender: "A", text: "x", copied: true).hasPrefix("✅ A: x"))
    }

    func testCopyPlusSendLabel() {
        XCTAssertEqual(BannerAction.copySend.title, "Copy + Send")
    }
}
