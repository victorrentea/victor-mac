import XCTest
@testable import VictorAddons

final class RightScrollZoomTests: XCTestCase {

    func testAPlainRightClickIsReplayedAtTheRelease() {
        var gesture = RightScrollZoom()
        XCTAssertEqual(gesture.down(enabled: true), .swallow)
        XCTAssertEqual(gesture.up(), .replayClick)
    }

    func testAScrollWhileHeldIsAZoomAndTheClickNeverGoesOut() {
        var gesture = RightScrollZoom()
        _ = gesture.down(enabled: true)
        XCTAssertTrue(gesture.scroll(buttonDown: true))
        XCTAssertTrue(gesture.scroll(buttonDown: true))
        XCTAssertEqual(gesture.up(), .swallow)
        // The next click is a click again.
        _ = gesture.down(enabled: true)
        XCTAssertEqual(gesture.up(), .replayClick)
    }

    func testDisabledLeavesTheButtonAlone() {
        var gesture = RightScrollZoom()
        XCTAssertEqual(gesture.down(enabled: false), .pass)
        XCTAssertFalse(gesture.scroll(buttonDown: true))
        XCTAssertEqual(gesture.up(), .pass)
    }

    func testAScrollWithNoPressScrolls() {
        var gesture = RightScrollZoom()
        XCTAssertFalse(gesture.scroll(buttonDown: false))
        XCTAssertFalse(gesture.scroll(buttonDown: true))
    }

    func testALostReleaseDoesNotLeaveScrollsZooming() {
        var gesture = RightScrollZoom()
        _ = gesture.down(enabled: true)
        XCTAssertFalse(gesture.scroll(buttonDown: false))
        XCTAssertFalse(gesture.scroll(buttonDown: true))
        XCTAssertEqual(gesture.up(), .pass)
    }
}
