import XCTest
@testable import VictorAddons

final class PowerPointAutoSavePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let deck = "/d/a.pptx"

    private func s(_ sec: Double, saved: Bool = false, path: String? = "/d/a.pptx",
                   presenting: Bool = false) -> PowerPointSample {
        PowerPointSample(at: t0.addingTimeInterval(sec), deck: "a.pptx", path: path, slide: 1,
                         slideID: 256, presenting: presenting, frontmost: true, saved: saved)
    }

    func testSavesAfterThreeMinutesUnsaved() {
        var p = PowerPointAutoSavePolicy()
        XCTAssertNil(p.consume(s(0), idle: 10))
        XCTAssertNil(p.consume(s(178), idle: 10))
        XCTAssertEqual(p.consume(s(180), idle: 10), deck)
    }

    func testWaitsForAPauseInTheHands() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        XCTAssertNil(p.consume(s(190), idle: 0.5))
        XCTAssertNil(p.consume(s(192), idle: 2.9))
        XCTAssertEqual(p.consume(s(194), idle: 3), deck)
    }

    func testNeverDuringASlideShowThenRightAfterIt() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        XCTAssertNil(p.consume(s(240, presenting: true), idle: 10))
        XCTAssertEqual(p.consume(s(242), idle: 10), deck)
    }

    func testADeckWithNoFileIsNeverSaved() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0, path: "Presentation1"), idle: 10)
        XCTAssertNil(p.consume(s(120, path: "Presentation1"), idle: 10))
        _ = p.consume(s(122, path: nil), idle: 10)
        XCTAssertNil(p.consume(s(240, path: nil), idle: 10))
    }

    /// Every scripted save goes through this gate: SlidesSeen once saved a bare "Presentation3"
    /// into the sandbox, and the new deck then closed without asking (2026-11-18).
    func testOnlyADeckWithAFileCanBeSavedByScript() {
        XCTAssertTrue(PowerPointDeck.hasFile("/d/a.pptx"))
        XCTAssertFalse(PowerPointDeck.hasFile("Presentation3"))
        XCTAssertFalse(PowerPointDeck.hasFile(""))
        XCTAssertFalse(PowerPointDeck.hasFile(nil))
    }

    func testSavingByHandRestartsTheClock() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        _ = p.consume(s(50, saved: true), idle: 10)
        XCTAssertNil(p.consume(s(52), idle: 10))
        XCTAssertNil(p.consume(s(220), idle: 10))
        XCTAssertEqual(p.consume(s(232), idle: 10), deck)
    }

    func testSwitchingDeckRestartsTheClock() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        XCTAssertNil(p.consume(s(70, path: "/d/b.pptx"), idle: 10))
        XCTAssertNil(p.consume(s(240, path: "/d/b.pptx"), idle: 10))
        XCTAssertEqual(p.consume(s(250, path: "/d/b.pptx"), idle: 10), "/d/b.pptx")
    }

    func testARefusedSaveIsRetriedAFullPeriodLater() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        XCTAssertEqual(p.consume(s(180), idle: 10), deck)
        XCTAssertNil(p.consume(s(182), idle: 10))
        XCTAssertEqual(p.consume(s(360), idle: 10), deck)
    }

    /// The daemon reads this file to tell AutoSave from ⌘S: a save under way has no mtime yet.
    func testScriptedSaveLogRecordsStartThenTheFilesMtime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saved = ScriptedSaveLog.fileURL
        ScriptedSaveLog.fileURL = dir.appendingPathComponent("saves.json")
        defer { ScriptedSaveLog.fileURL = saved; try? FileManager.default.removeItem(at: dir) }
        let deckFile = dir.appendingPathComponent("a.pptx")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: deckFile)
        let mtime = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: deckFile.path)

        ScriptedSaveLog.started(deckFile.path)
        XCTAssertNotNil(ScriptedSaveLog.read()[deckFile.path]?["started"])
        XCTAssertNil(ScriptedSaveLog.read()[deckFile.path]?["mtime"])
        ScriptedSaveLog.finished(deckFile.path)
        XCTAssertEqual(ScriptedSaveLog.read()[deckFile.path]?["mtime"] as? Double, 1_800_000_000)
    }
}
