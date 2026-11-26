import XCTest
@testable import VictorAddons

/// ✍️ The mid-clip prompt of a videos.json entry (Spartans: BUILDERS!, or what Victor typed).
final class VideoPromptTests: XCTestCase {
    private let json = """
    {"id":"aNa3Co83_gk","title":"Spartans","startSeconds":0,"file":"aNa3Co83_gk.mp4","url":null,
     "prompt":{"atSeconds":3.95,"question":"Spartans! What is your profession?","defaultAnswer":"Builders",
               "cues":[[4.1,5.05],[5.15,6.15],[6.2,8.0]],"uppercase":true,"suffix":"!"}}
    """

    private func prompt() throws -> VideoLibrary.Prompt {
        try XCTUnwrap(JSONDecoder().decode(VideoLibrary.Entry.self, from: Data(json.utf8)).prompt)
    }

    func testAnEntryWithoutAPromptStillDecodes() throws {
        let plain = #"{"id":"x","title":"X","startSeconds":0,"file":"x.mp4","url":null}"#
        XCTAssertNil(try JSONDecoder().decode(VideoLibrary.Entry.self, from: Data(plain.utf8)).prompt)
    }

    func testTheTypedWordBecomesTheShout() throws {
        let p = try prompt()
        XCTAssertEqual(p.caption(for: "testers"), "TESTERS!")
        XCTAssertEqual(p.caption(for: "  "), "BUILDERS!", "an empty answer keeps the default")
    }

    func testTheCaptionIsUpOnlyDuringTheShouts() throws {
        let p = try prompt()
        XCTAssertFalse(p.showsCaption(at: 3.95), "not while the question is on screen")
        XCTAssertTrue(p.showsCaption(at: 4.5))
        XCTAssertFalse(p.showsCaption(at: 5.1), "a gap between two shouts")
        XCTAssertTrue(p.showsCaption(at: 7.9))
        XCTAssertFalse(p.showsCaption(at: 8.0))
    }

    func testTheClipSitsUnderScreenBrushCanvas() {
        // ScreenBrush draws at 29; a clip above it hid every stroke (2026-11-26).
        XCTAssertLessThan(VideoWindow.windowLevel.rawValue, 29)
        XCTAssertGreaterThan(VideoWindow.windowLevel.rawValue, NSWindow.Level.statusBar.rawValue)
    }
}
