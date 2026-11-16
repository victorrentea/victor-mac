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
