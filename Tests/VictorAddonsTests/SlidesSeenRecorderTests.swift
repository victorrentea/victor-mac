import XCTest
@testable import VictorAddons

/// The recorder's flow with PowerPoint, the clock of his hands and Drive stood in:
/// what is saved when, what the day log names, what the daemon is told.
final class SlidesSeenRecorderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var dir: URL!
    private var deckA: String!
    private var deckB: String!

    // The world, as the recorder's queue sees it (read here only after `drain`).
    private var idle: TimeInterval = 10
    private var saveWorks = true
    private var otherDeckUnsaved = false
    private var afterSave: () -> Void = {}
    private var saves: [String] = []
    private var events: [String] = []
    private var recorder: SlidesSeenRecorder!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        deckA = dir.appendingPathComponent("a.pptx").path
        deckB = dir.appendingPathComponent("b.pptx").path
        try Data("a as first saved".utf8).write(to: URL(fileURLWithPath: deckA))
        try Data("b as first saved".utf8).write(to: URL(fileURLWithPath: deckB))

        var world = SlidesSeenWorld()
        world.root = dir.appendingPathComponent("slides-seen")
        world.idle = { [unowned self] in self.idle }
        world.uploading = { _ in false }
        world.save = { [unowned self] path in
            self.saves.append(path)
            if self.saveWorks {
                // A real save: other bytes, another size, so another snapshot.
                try? Data("saved again, \(self.saves.count) time(s), with his edits".utf8)
                    .write(to: URL(fileURLWithPath: path))
            }
            self.afterSave()
            return self.saveWorks
        }
        world.needsSave = { [unowned self] _ in self.otherDeckUnsaved }
        world.spotlightImport = { _ in }
        recorder = SlidesSeenRecorder(world: world)
        recorder.onEvent = { [unowned self] e in
            self.events.append("\(e["phase"] ?? "?") \(e["slide_id"] ?? "?")")
        }
    }

    override func tearDownWithError() throws {
        recorder.drain()
        try? FileManager.default.removeItem(at: dir)
    }

    /// One probe every 2 s, like `PowerPointMonitor`.
    private func show(_ path: String, slide id: Int, from: Double, for seconds: Double,
                      saved: Bool, presenting: Bool = false) {
        var t = from
        while t <= from + seconds {
            recorder.consume(PowerPointSample(
                at: t0.addingTimeInterval(t), deck: URL(fileURLWithPath: path).lastPathComponent, path: path,
                slide: 1, slideID: id, presenting: presenting, frontmost: true, saved: saved))
            t += 2
        }
        recorder.drain()
    }

    private func dayLog() throws -> [[String: Any]] {
        let logDir = dir.appendingPathComponent("slides-seen/log")
        let files = try FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)
        return try files.flatMap { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }
    }

    private func copyName(of path: String) throws -> String {
        "\(try XCTUnwrap(SlidesSeenRecorder.sha256(path)).prefix(16)).pptx"
    }

    // MARK: - the copy the day log names (training-summarizer exports the slide from it)

    func testTheDayLogNamesTheDeckAsSavedOnLeavingTheSlideNotAsItWasAtTheSeventhSecond() throws {
        let asFirstSaved = try copyName(of: deckA)
        idle = 0.5  // typing on the slide through its 7th second
        show(deckA, slide: 256, from: 0, for: 10, saved: false)
        XCTAssertEqual(saves, [], "no save under his hands")
        XCTAssertEqual(events, ["qualified 256"])

        idle = 5  // he moved on and paused
        show(deckA, slide: 300, from: 12, for: 0, saved: false)

        XCTAssertEqual(saves, [deckA])
        XCTAssertEqual(events, ["qualified 256", "closed 256"])
        let line = try XCTUnwrap(dayLog().first)
        let named = try XCTUnwrap(line["snapshot"] as? String)
        XCTAssertEqual(named, try copyName(of: deckA), "the deck with his edits")
        XCTAssertNotEqual(named, asFirstSaved)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("slides-seen/decks.noindex/\(named)").path))
    }

    func testAnUnchangedDeckKeepsTheCopyFromTheSeventhSecond() throws {
        let asFirstSaved = try copyName(of: deckA)
        show(deckA, slide: 256, from: 0, for: 10, saved: true)
        show(deckA, slide: 300, from: 12, for: 0, saved: true)

        XCTAssertEqual(saves, [])
        XCTAssertEqual(try XCTUnwrap(dayLog().first)["snapshot"] as? String, asFirstSaved)
    }

    // MARK: - a slide reported while its edits were not on disk is reported again once they are

    func testASlideReportedUnsavedAfterAMinuteOfBusyHandsIsReportedAgainOnceTheDeckIsSaved() {
        idle = 0.5
        show(deckA, slide: 256, from: 0, for: 10, saved: false)
        show(deckA, slide: 300, from: 12, for: 58, saved: false)
        XCTAssertFalse(events.contains("closed 256"), "still waiting for his hands")

        show(deckA, slide: 300, from: 72, for: 0, saved: false)  // a minute: reported as it is on disk
        XCTAssertEqual(events.filter { $0 == "closed 256" }.count, 1)
        XCTAssertEqual(saves, [], "never saved under his hands")

        show(deckA, slide: 300, from: 74, for: 0, saved: true)  // he pressed ⌘S
        XCTAssertEqual(events.filter { $0 == "closed 256" }.count, 2)

        show(deckA, slide: 300, from: 76, for: 4, saved: true)
        XCTAssertEqual(events.filter { $0 == "closed 256" }.count, 2, "once")
    }

    func testASlideWhoseSaveWasRefusedIsReportedAgainOnceTheDeckIsSaved() {
        saveWorks = false
        show(deckA, slide: 256, from: 0, for: 10, saved: true)
        show(deckA, slide: 256, from: 12, for: 0, saved: false)  // edited after its 7th second
        show(deckA, slide: 300, from: 14, for: 0, saved: false)
        XCTAssertEqual(saves, [deckA])
        XCTAssertEqual(events.filter { $0 == "closed 256" }.count, 1)

        show(deckA, slide: 300, from: 16, for: 0, saved: true)
        XCTAssertEqual(events.filter { $0 == "closed 256" }.count, 2)
    }

    func testASlideSavedOnLeavingIsReportedOnce() {
        show(deckA, slide: 256, from: 0, for: 10, saved: true)
        show(deckA, slide: 256, from: 12, for: 0, saved: false)
        show(deckA, slide: 300, from: 14, for: 0, saved: false)
        show(deckA, slide: 300, from: 16, for: 4, saved: true)

        XCTAssertEqual(saves, [deckA])
        XCTAssertEqual(events.filter { $0 == "closed 256" }.count, 1)
    }

    func testPowerPointQuittingReportsTheUnsavedOnesAgainItMayHaveSavedOnItsWayOut() {
        show(deckA, slide: 256, from: 0, for: 10, saved: false, presenting: true)
        show(deckA, slide: 300, from: 12, for: 0, saved: false, presenting: true)  // a slide show: no save
        XCTAssertEqual(events.filter { $0 == "closed 256" }.count, 1)

        recorder.consume(.gone(at: t0.addingTimeInterval(20)))
        recorder.drain()
        XCTAssertEqual(events.filter { $0 == "closed 256" }.count, 2)
        XCTAssertEqual(saves, [])
    }

    // MARK: - the save at the 7th second

    func testNoSaveAtTheSeventhSecondOfASlideShow() {
        show(deckA, slide: 256, from: 0, for: 10, saved: false, presenting: true)
        XCTAssertEqual(saves, [])
        XCTAssertEqual(events, ["qualified 256"])
    }

    func testSavedAtTheSeventhSecondWhenHisHandsRest() {
        show(deckA, slide: 256, from: 0, for: 10, saved: false)
        XCTAssertEqual(saves, [deckA])
    }

    // MARK: - his hands are asked about again before each save

    func testASaveHeStartsTypingDuringDoesNotLetTheNextOneThrough() {
        idle = 0.5
        show(deckA, slide: 256, from: 0, for: 10, saved: false)
        show(deckB, slide: 900, from: 12, for: 10, saved: false)  // a.pptx left for b.pptx
        show(deckB, slide: 901, from: 24, for: 0, saved: false)   // and slide 900 of b.pptx left
        XCTAssertEqual(saves, [])

        idle = 5
        otherDeckUnsaved = true
        afterSave = { [unowned self] in self.idle = 0 }  // typing again by the time a.pptx is saved
        show(deckB, slide: 901, from: 26, for: 0, saved: false)
        XCTAssertEqual(saves, [deckA], "b.pptx waits for the next pause")
        XCTAssertEqual(events.filter { $0.hasPrefix("closed") }, ["closed 256"])

        afterSave = {}
        idle = 5
        show(deckB, slide: 901, from: 28, for: 0, saved: false)
        XCTAssertEqual(saves, [deckA, deckB])
        XCTAssertEqual(events.filter { $0.hasPrefix("closed") }, ["closed 256", "closed 900"])
    }
}
