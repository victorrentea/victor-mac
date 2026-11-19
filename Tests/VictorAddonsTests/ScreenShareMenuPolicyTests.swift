import XCTest
@testable import VictorAddons

final class ScreenShareMenuPolicyTests: XCTestCase {
    func testNothingSharedNoItem() {
        XCTAssertNil(ScreenShareMenuPolicy.reason(externalScreens: 0, meetingAppRunning: false, sharing: false))
    }
    func testProjectorAloneShowsIt() {
        XCTAssertEqual(ScreenShareMenuPolicy.reason(externalScreens: 1, meetingAppRunning: false, sharing: false), .external)
    }
    func testMeetingAppOutranksCable() {
        XCTAssertEqual(ScreenShareMenuPolicy.reason(externalScreens: 2, meetingAppRunning: true, sharing: false), .meetingApp)
    }
    func testLiveShareOutranksEverything() {
        XCTAssertEqual(ScreenShareMenuPolicy.reason(externalScreens: 0, meetingAppRunning: true, sharing: true), .sharing)
        // The share watch can see a share a moment after the app quit; still a share.
        XCTAssertEqual(ScreenShareMenuPolicy.reason(externalScreens: 0, meetingAppRunning: false, sharing: true), .sharing)
    }
    func testTooltipCountsScreens() {
        XCTAssertEqual(ScreenShareMenuPolicy.reason(externalScreens: 0, meetingAppRunning: false, sharing: false, virtualDesktopUp: true), .virtualDesktop)
        XCTAssertEqual(ScreenShareMenuPolicy.reason(externalScreens: 1, meetingAppRunning: true, sharing: false, virtualDesktopUp: true), .meetingApp)
        XCTAssertEqual(ScreenShareMenuPolicy.tooltip(.external, externalScreens: 1), "An external screen is connected")
        XCTAssertEqual(ScreenShareMenuPolicy.tooltip(.external, externalScreens: 2), "2 external screens are connected")
    }
}
