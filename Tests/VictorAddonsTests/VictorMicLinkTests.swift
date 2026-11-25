import XCTest
@testable import VictorAddons

final class VictorMicLinkTests: XCTestCase {
    private let glyph: (String) -> String? = { $0.contains("XLR") ? "🎙️" : nil }

    func testNotRunning() {
        let r = VictorMicLink.row(nil, glyph: glyph)
        XCTAssertEqual(r.title, "🪄 Victor Noiseless — app not running")
        XCTAssertFalse(r.enabled)
    }

    func testNoDriver() {
        let r = VictorMicLink.row(.init(driver: false), glyph: glyph)
        XCTAssertEqual(r.title, "🪄 Victor Noiseless — driver not installed")
        XCTAssertFalse(r.enabled)
    }

    func testIdle() {
        let r = VictorMicLink.row(.init(driver: true, source: "Elgato Wave XLR"), glyph: glyph)
        XCTAssertEqual(r.title, "🪄 Victor Noiseless — idle, no app listening")
        XCTAssertTrue(r.enabled)
        XCTAssertTrue(r.ticked)
    }

    func testCleaningNamesTheMicWithItsGlyph() {
        let r = VictorMicLink.row(.init(driver: true, reading: true, running: true, source: "Elgato Wave XLR"), glyph: glyph)
        XCTAssertEqual(r.title, "🪄 Victor Noiseless — cleaning 🎙️ Elgato Wave XLR")
    }

    func testBypassed() {
        let r = VictorMicLink.row(.init(driver: true, reading: true, running: true, clean: false, source: "MacBook Pro Microphone"), glyph: glyph)
        XCTAssertEqual(r.title, "🪄 Victor Noiseless — raw MacBook Pro Microphone, not cleaned")
        XCTAssertFalse(r.ticked)
    }

    func testParsesTheAppsState() {
        let json = #"{"driver":true,"reading":true,"running":true,"clean":false,"source":"Bose"}"#
        XCTAssertEqual(VictorMicLink.parse(Data(json.utf8)),
                       .init(driver: true, reading: true, running: true, clean: false, source: "Bose"))
    }
}
