import AppKit
import XCTest
@testable import VictorAddons

final class CaretBubblePolicyTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let visible = CGRect(x: 0, y: 0, width: 1728, height: 1080)

    // MARK: cocoaRect

    func testAXRectIsFlippedToCocoa() {
        let rect = CaretBubblePolicy.cocoaRect(fromAX: CGRect(x: 100, y: 200, width: 0, height: 20),
                                               primaryHeight: 1117, screens: [screen])
        XCTAssertEqual(rect, CGRect(x: 100, y: 1117 - 220, width: 0, height: 20))
    }

    func testZeroRectMeansUnknown() {
        XCTAssertNil(CaretBubblePolicy.cocoaRect(fromAX: .zero, primaryHeight: 1117, screens: [screen]))
    }

    func testOffScreenRectIsRejected() {
        XCTAssertNil(CaretBubblePolicy.cocoaRect(fromAX: CGRect(x: 5000, y: 200, width: 0, height: 20),
                                                 primaryHeight: 1117, screens: [screen]))
    }

    func testAbsurdHeightIsRejected() {
        XCTAssertNil(CaretBubblePolicy.cocoaRect(fromAX: CGRect(x: 10, y: 10, width: 0, height: 900),
                                                 primaryHeight: 1117, screens: [screen]))
        XCTAssertNil(CaretBubblePolicy.cocoaRect(fromAX: CGRect(x: 10, y: 10, width: 0, height: 1),
                                                 primaryHeight: 1117, screens: [screen]))
    }

    // MARK: fontSize

    func testReportedSizeWins() {
        XCTAssertEqual(CaretBubblePolicy.fontSize(reported: 13, caretHeight: 40), 13)
    }

    func testSizeFromCaretHeightWhenUnreported() {
        XCTAssertEqual(CaretBubblePolicy.fontSize(reported: nil, caretHeight: 24), 20)
    }

    func testSizeIsClamped() {
        XCTAssertEqual(CaretBubblePolicy.fontSize(reported: 6, caretHeight: 8), 11)
        XCTAssertEqual(CaretBubblePolicy.fontSize(reported: 96, caretHeight: 120), 40)
    }

    // MARK: colors

    func testDocumentColorsUsedWhenBothKnownAndReadable() {
        let c = CaretBubblePolicy.colors(foreground: .black, background: .white,
                                         fallbackText: .red, fallbackBackground: .blue)
        XCTAssertEqual(c.text, NSColor.black.usingColorSpace(.sRGB))
    }

    func testForegroundAloneFallsBack() {
        let c = CaretBubblePolicy.colors(foreground: .black, background: nil,
                                         fallbackText: .red, fallbackBackground: .blue)
        XCTAssertEqual(c.text, .red)
        XCTAssertEqual(c.background, .blue)
    }

    func testLowContrastFallsBack() {
        let c = CaretBubblePolicy.colors(foreground: NSColor(white: 0.5, alpha: 1),
                                         background: NSColor(white: 0.55, alpha: 1),
                                         fallbackText: .red, fallbackBackground: .blue)
        XCTAssertEqual(c.text, .red)
    }

    // MARK: place

    func testAboveTheCaretWithTextOverTheCaret() {
        let caret = CGRect(x: 400, y: 500, width: 0, height: 18)
        let p = CaretBubblePolicy.place(size: CGSize(width: 300, height: 80), caret: caret,
                                        visible: visible, contentInset: 10)
        XCTAssertTrue(p.above)
        XCTAssertEqual(p.frame.minY, caret.maxY + 4)
        XCTAssertEqual(p.frame.minX, 390)
        XCTAssertEqual(p.tailX, 21)   // held off the rounded corner
    }

    func testBelowWhenNoRoomAbove() {
        let caret = CGRect(x: 400, y: 1050, width: 0, height: 18)
        let p = CaretBubblePolicy.place(size: CGSize(width: 300, height: 80), caret: caret,
                                        visible: visible, contentInset: 10)
        XCTAssertFalse(p.above)
        XCTAssertEqual(p.frame.maxY, caret.minY - 4)
    }

    func testSlidesLeftAtTheRightEdgeAndTailStillPointsAtCaret() {
        let caret = CGRect(x: 1700, y: 500, width: 0, height: 18)
        let p = CaretBubblePolicy.place(size: CGSize(width: 300, height: 80), caret: caret,
                                        visible: visible, contentInset: 10)
        XCTAssertEqual(p.frame.maxX, visible.maxX - 6)
        XCTAssertEqual(p.tailX, 278)
    }
}
