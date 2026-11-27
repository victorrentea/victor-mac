import AppKit
import XCTest
@testable import VictorAddons

final class JoinLinkHintTests: XCTestCase {
    // The laptop's panel, with the link strip under a 33 pt menu bar.
    private let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
    private let banner = NSRect(x: 0, y: 950, width: 1728, height: 134)

    func testHintHangsCentredJustUnderTheLink() {
        let (frame, g) = JoinLinkHint.layout(screen: retina, banner: banner, widthPerPoint: 15)

        XCTAssertEqual(frame.midX, retina.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(frame.maxY, banner.minY)
        XCTAssertGreaterThan(frame.maxY, banner.minY - g.fontSize * 0.2)
        XCTAssertTrue(retina.contains(frame))
    }

    func testTextSpansAboutTwoFifthsOfTheScreen() {
        let (_, g) = JoinLinkHint.layout(screen: retina, banner: banner, widthPerPoint: 15)

        XCTAssertEqual(g.lineWidth / retina.width, JoinLinkHint.widthFraction, accuracy: 0.02)
    }

    func testAShortWideScreenCapsTheFontByHeight() {
        let strip = NSRect(x: 0, y: 0, width: 3000, height: 600)
        let (_, g) = JoinLinkHint.layout(screen: strip, banner: NSRect(x: 0, y: 500, width: 3000, height: 100), widthPerPoint: 15)

        XCTAssertEqual(g.fontSize, floor(600 * JoinLinkHint.maxFontFraction))
    }

    func testArrowRisesFromTheTextEndToThePanelTop() {
        let g = JoinLinkHint.geometry(fontSize: 50, widthPerPoint: 15)

        XCTAssertGreaterThan(g.arrowStart.x, g.textOrigin.x + g.lineWidth * cos(JoinLinkHint.tilt))
        XCTAssertGreaterThan(g.arrowTip.y, g.arrowStart.y)
        XCTAssertLessThanOrEqual(g.arrowTip.y, g.size.height)
        XCTAssertLessThan(g.arrowTip.x, g.size.width)
    }
}
