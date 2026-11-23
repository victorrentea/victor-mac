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

    /// PowerPoint refuses a save while Drive holds the file for its upload: the save waits for
    /// the upload to end, it does not lose three more minutes.
    func testWaitsWhileDriveStillUploadsThePreviousSaveWithoutRestartingTheClock() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        XCTAssertNil(p.consume(s(180), idle: 10, uploading: true))
        XCTAssertNil(p.consume(s(182), idle: 10, uploading: true))
        XCTAssertEqual(p.consume(s(184), idle: 10, uploading: false), deck)
    }

    // MARK: - when a scripted save may run

    func testAScriptedSaveWaitsForTheHandsToPause() {
        XCTAssertFalse(ScriptedSaveMoment.allows(idle: 0.4, frontmost: true, uploading: false))
        XCTAssertFalse(ScriptedSaveMoment.allows(idle: 2.9, frontmost: true, uploading: false))
        XCTAssertTrue(ScriptedSaveMoment.allows(idle: 3, frontmost: true, uploading: false))
    }

    /// Typing in another app is not typing in PowerPoint: no ⌘S can reach it there.
    func testBehindAnotherAppTheHandsDoNotMatter() {
        XCTAssertTrue(ScriptedSaveMoment.allows(idle: 0.1, frontmost: false, uploading: false))
    }

    func testNeverWhileDriveStillUploadsThePreviousSave() {
        XCTAssertFalse(ScriptedSaveMoment.allows(idle: 60, frontmost: true, uploading: true))
        XCTAssertFalse(ScriptedSaveMoment.allows(idle: 60, frontmost: false, uploading: true))
    }

    func testAFileWithASecondHardLinkIsBeingUploaded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let deckFile = dir.appendingPathComponent("a.pptx")
        try Data("x".utf8).write(to: deckFile)
        XCTAssertFalse(PowerPointDeck.uploading(deckFile.path))
        // What Google Drive does for the time of the upload: ~/My Drive/.tmp.driveupload/<n>.
        let link = dir.appendingPathComponent("upload-1")
        try FileManager.default.linkItem(at: deckFile, to: link)
        XCTAssertTrue(PowerPointDeck.uploading(deckFile.path))
        try FileManager.default.removeItem(at: link)
        XCTAssertFalse(PowerPointDeck.uploading(deckFile.path))
        XCTAssertFalse(PowerPointDeck.uploading(dir.appendingPathComponent("missing.pptx").path))
    }

    // MARK: - ScriptedSaveLog

    private func withLog(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saved = ScriptedSaveLog.fileURL
        ScriptedSaveLog.fileURL = dir.appendingPathComponent("saves.json")
        defer { ScriptedSaveLog.fileURL = saved; try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body(dir)
    }

    /// A refused save wrote nothing: the file still carries the mtime of the save before it,
    /// maybe Victor's ⌘S, and the log must not claim that one.
    func testASaveThatWroteNothingLeavesTheLogAsItWas() throws {
        try withLog { dir in
            let other = dir.appendingPathComponent("b.pptx").path
            let now = Date()
            ScriptedSaveLog.started(other, at: now.addingTimeInterval(-60))
            ScriptedSaveLog.finished(other, at: now.addingTimeInterval(-59))
            let before = ScriptedSaveLog.read()[other]?["mtime"] as? Double

            let previous = ScriptedSaveLog.started(other, at: now)
            XCTAssertNil(ScriptedSaveLog.read()[other]?["mtime"])
            ScriptedSaveLog.restore(other, previous)
            XCTAssertEqual(ScriptedSaveLog.read()[other]?["mtime"] as? Double, before)

            let fresh = dir.appendingPathComponent("c.pptx").path
            let none = ScriptedSaveLog.started(fresh, at: now)
            XCTAssertNil(none)
            ScriptedSaveLog.restore(fresh, none)
            XCTAssertNil(ScriptedSaveLog.read()[fresh])
        }
    }

    func testTellsItsOwnSaveFromOneMadeByHand() {
        let saved = Date(timeIntervalSince1970: 1_800_000_003.25)
        let entry: [String: Any] = ["started": 1_800_000_000.0, "mtime": 1_800_000_003.25]
        XCTAssertTrue(ScriptedSaveLog.isScripted(entry: entry, mtime: saved))
        XCTAssertFalse(ScriptedSaveLog.isScripted(entry: entry, mtime: saved.addingTimeInterval(500)))  // a later ⌘S
        XCTAssertFalse(ScriptedSaveLog.isScripted(entry: nil, mtime: saved))
        // Under way: no mtime yet, so any save since it started counts, for two minutes.
        let underWay: [String: Any] = ["started": 1_800_000_000.0]
        XCTAssertTrue(ScriptedSaveLog.isScripted(entry: underWay, mtime: Date(timeIntervalSince1970: 1_800_000_002)))
        XCTAssertFalse(ScriptedSaveLog.isScripted(entry: underWay, mtime: Date(timeIntervalSince1970: 1_800_005_000)))
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
