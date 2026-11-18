import AppKit
import XCTest
@testable import VictorAddons

final class JoinLinkQRFrameTests: XCTestCase {
    private let screen = NSRect(x: 100, y: 50, width: 1600, height: 1000)
    private let banner = NSRect(x: 100, y: 850, width: 1600, height: 175)

    func testSmallQRSitsInTheBottomRightCorner() {
        let qr = JoinLinkBanner.qrFrame(screen: screen, banner: banner, expanded: false)

        XCTAssertEqual(qr, NSRect(x: 1380, y: 70, width: 300, height: 300))
    }

    func testExpandedQRFillsTheScreenUnderTheLink() {
        let qr = JoinLinkBanner.qrFrame(screen: screen, banner: banner, expanded: true)

        XCTAssertEqual(qr, NSRect(x: 520, y: 70, width: 760, height: 760))
        XCTAssertLessThanOrEqual(qr.maxY, banner.minY)
        XCTAssertEqual(qr.midX, screen.midX)
    }

    func testExpandedQRStaysOnAPortraitScreen() {
        let tall = NSRect(x: 0, y: 0, width: 600, height: 1000)
        let qr = JoinLinkBanner.qrFrame(screen: tall, banner: NSRect(x: 0, y: 900, width: 600, height: 75), expanded: true)

        XCTAssertEqual(qr.width, 560)
        XCTAssertTrue(tall.contains(qr))
    }
}

final class JoinLinkCompactLayoutTests: XCTestCase {
    // The laptop: 1728 wide, a 33 pt bar, status icons from x = 1172.
    private let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)

    func testCompactLinkSitsCentredInTheMenuBar() {
        let l = JoinLinkBanner.compactLayout(screen: retina, barHeight: 33, statusItemsMinX: 1172, widthPerPoint: 18)

        XCTAssertEqual(l.fontSize, 19)
        XCTAssertEqual(l.frame.midX, retina.midX, accuracy: 1)
        XCTAssertEqual(l.frame.maxY, retina.maxY - 2)
        XCTAssertEqual(l.frame.minY, retina.maxY - 33 + 2)
    }

    func testCompactLinkMovesLeftRatherThanCoverAStatusIcon() {
        let l = JoinLinkBanner.compactLayout(screen: retina, barHeight: 33, statusItemsMinX: 900, widthPerPoint: 18)

        XCTAssertEqual(l.fontSize, 19)
        XCTAssertEqual(l.frame.maxX, 900 - JoinLinkBanner.compactGap)
    }

    func testCompactLinkShrinksOnlyWhenTheWholeBarIsTooNarrow() {
        let l = JoinLinkBanner.compactLayout(screen: retina, barHeight: 33, statusItemsMinX: 300, widthPerPoint: 18)

        XCTAssertLessThan(l.fontSize, 19)
        XCTAssertGreaterThanOrEqual(l.frame.minX, retina.minX + JoinLinkBanner.compactGap)
        XCTAssertLessThanOrEqual(l.frame.maxX, 300 - JoinLinkBanner.compactGap)
    }

    func testCompactLinkOnASecondScreenStaysOnIt() {
        let right = NSRect(x: 1728, y: 0, width: 1920, height: 1080)
        let l = JoinLinkBanner.compactLayout(screen: right, barHeight: 24, statusItemsMinX: nil, widthPerPoint: 18)

        XCTAssertEqual(l.frame.midX, right.midX, accuracy: 1)
        XCTAssertTrue(right.contains(l.frame))
    }
}
