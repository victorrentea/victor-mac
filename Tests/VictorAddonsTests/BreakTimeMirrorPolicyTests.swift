import XCTest
@testable import VictorAddons

final class BreakTimeMirrorPolicyTests: XCTestCase {
    private let asus = (id: CGDirectDisplayID(1), bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let retina = (id: CGDirectDisplayID(2), bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080))

    /// Presenter View on the ASUS, slides on the Retina where the watch is:
    /// the copy goes on the ASUS only.
    func testPresenterViewScreenGetsTheCopyNotTheWatchScreen() {
        let got = BreakTimeMirrorPolicy.screens(displays: [asus, retina],
                                                powerPointWindows: [asus.bounds, retina.bounds],
                                                watchDisplay: retina.id)
        XCTAssertEqual(got, [asus.id])
    }

    /// The editor below the menu bar (y 30, 1050 tall) is not full screen.
    func testEditorWindowDoesNotCount() {
        let editor = CGRect(x: -1920, y: 30, width: 1920, height: 1050)
        XCTAssertEqual(BreakTimeMirrorPolicy.screens(displays: [asus, retina],
                                                     powerPointWindows: [editor],
                                                     watchDisplay: asus.id), [])
    }

    func testNoShowNoCopy() {
        XCTAssertEqual(BreakTimeMirrorPolicy.screens(displays: [asus, retina], powerPointWindows: [],
                                                     watchDisplay: retina.id), [])
    }

    func testTitle() {
        XCTAssertEqual(BreakTimeMirrorPolicy.title(remaining: 411, paused: false), "☕ 06:51")
        XCTAssertEqual(BreakTimeMirrorPolicy.title(remaining: 411, paused: true), "☕ 06:51 ⏸")
    }
}
