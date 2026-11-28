import XCTest
@testable import VictorAddons

/// A clip runs to its end — the player no longer cuts it at 60 s (2026-11-28:
/// "dacă vreau să mă uit la tot, de ce-l oprești?"). The minute survives only
/// as the floor of the window's life, so a short clip closes exactly as before.
final class VideoPlayerLifetimeTests: XCTestCase {
    private func delay(_ left: TimeInterval?) -> TimeInterval {
        VideoPlayer.killDelay(left: left, minimum: 60, linger: 10)
    }

    func testShortClipKeepsTheMinute() {
        XCTAssertEqual(delay(20), 60)
    }

    func testLongClipPlaysToItsEndThenLingers() {
        XCTAssertEqual(delay(282), 292)   // Hyperoptimized Engineer from 0:00
    }

    func testUnknownLengthFallsBackToTheMinute() {
        XCTAssertEqual(delay(nil), 60)
        XCTAssertEqual(delay(.nan), 60)
        XCTAssertEqual(delay(0), 60)
    }
}
