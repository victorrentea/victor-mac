import XCTest
@testable import VictorAddons

final class SlidesSeenCloseSaveTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func span(path: String? = "/d/a.pptx") -> SlideSpan {
        SlideSpan(deck: "a.pptx", path: path, slide: 4, slideID: 256, presenting: false,
                  start: t0, end: t0.addingTimeInterval(12))
    }

    private func s(path: String? = "/d/a.pptx", deck: String = "a.pptx", saved: Bool,
                   presenting: Bool = false, front: Bool = true) -> PowerPointSample {
        PowerPointSample(at: t0.addingTimeInterval(14), deck: deck, path: path, slide: 5, slideID: 300,
                         presenting: presenting, frontmost: front, saved: saved)
    }

    func testSameDeckWithUnsavedEditsIsSaved() {
        XCTAssertEqual(SlidesSeenCloseSave.decide(span: span(), closing: s(saved: false)), .save("/d/a.pptx"))
    }

    func testSameDeckAlreadySavedIsLeftAlone() {
        XCTAssertEqual(SlidesSeenCloseSave.decide(span: span(), closing: s(saved: true)), SlidesSeenCloseSave.none)
    }

    func testPowerPointInTheBackgroundStillSavesTheSameDeck() {
        XCTAssertEqual(SlidesSeenCloseSave.decide(span: span(), closing: s(saved: false, front: false)), .save("/d/a.pptx"))
    }

    func testNeverDuringASlideShow() {
        XCTAssertEqual(SlidesSeenCloseSave.decide(span: span(), closing: s(saved: false, presenting: true)),
                       SlidesSeenCloseSave.none)
    }

    func testAnotherDeckActiveAsksAboutTheSpansOwnDeck() {
        // The closing sample's `saved` is about b.pptx: it says nothing of a.pptx.
        XCTAssertEqual(SlidesSeenCloseSave.decide(span: span(), closing: s(path: "/d/b.pptx", deck: "b.pptx", saved: true)),
                       .saveIfUnsaved("/d/a.pptx"))
    }

    func testPowerPointGoneSavesNothing() {
        XCTAssertEqual(SlidesSeenCloseSave.decide(span: span(), closing: .gone(at: t0)), SlidesSeenCloseSave.none)
    }

    func testDeckWithoutAFileIsNeverSaved() {
        XCTAssertEqual(SlidesSeenCloseSave.decide(span: span(path: "Presentation1"), closing: s(path: "Presentation1", saved: false)),
                       SlidesSeenCloseSave.none)
    }

    // MARK: - the save waits for his hands (a ⌘S of his must never meet ours)

    private func step(_ closing: PowerPointSample, waited: TimeInterval = 2, idle: TimeInterval,
                      uploading: Bool = false) -> SlidesSeenCloseSave.Step {
        SlidesSeenCloseSave.step(span: span(), now: closing, waited: waited, idle: idle, uploading: uploading)
    }

    func testTheSaveOnLeavingASlideWaitsForTheHandsToPause() {
        XCTAssertEqual(step(s(saved: false), idle: 0.3), .wait)
        XCTAssertEqual(step(s(saved: false), idle: 3), .saveThenSend("/d/a.pptx"))
    }

    /// He pressed ⌘S himself while we waited: nothing left to save, the slide is reported.
    func testHisOwnSaveInTheMeantimeLeavesNothingToDo() {
        XCTAssertEqual(step(s(saved: true), idle: 0.3), .send)
    }

    func testTheSaveWaitsForDriveToFinishThePreviousUpload() {
        XCTAssertEqual(step(s(saved: false), idle: 30, uploading: true), .wait)
    }

    func testBehindAnotherAppItIsSavedAtOnce() {
        XCTAssertEqual(step(s(saved: false, front: false), idle: 0.1), .saveThenSend("/d/a.pptx"))
    }

    func testAnotherDeckInFrontAsksPowerPointOnceTheHandsPause() {
        let other = s(path: "/d/b.pptx", deck: "b.pptx", saved: true)
        XCTAssertEqual(step(other, idle: 0.3), .wait)
        XCTAssertEqual(step(other, idle: 5), .askThenSend("/d/a.pptx"))
    }

    /// Hands that never pause: the slide is reported as it is on disk, never saved under them.
    func testAfterAMinuteItIsReportedWithoutTheSave() {
        XCTAssertEqual(step(s(saved: false), waited: 59, idle: 0.3), .wait)
        XCTAssertEqual(step(s(saved: false), waited: 60, idle: 0.3), .send)
    }

    func testASlideShowOrPowerPointGoneReportsAtOnce() {
        XCTAssertEqual(step(s(saved: false, presenting: true), idle: 0.3), .send)
        XCTAssertEqual(step(.gone(at: t0), idle: 0.3), .send)
    }

    // MARK: - the save at the 7th second, and what a report left behind

    func testTheSaveAtTheSeventhSecondNeedsUnsavedEditsRestingHandsAndNoSlideShow() {
        XCTAssertTrue(SlidesSeenCloseSave.saveWhenQualified(s(saved: false), idle: 3, uploading: false))
        XCTAssertFalse(SlidesSeenCloseSave.saveWhenQualified(s(saved: true), idle: 3, uploading: false))
        XCTAssertFalse(SlidesSeenCloseSave.saveWhenQualified(s(saved: false), idle: 0.5, uploading: false))
        XCTAssertFalse(SlidesSeenCloseSave.saveWhenQualified(s(saved: false, presenting: true), idle: 30, uploading: false))
        XCTAssertFalse(SlidesSeenCloseSave.saveWhenQualified(s(saved: false), idle: 30, uploading: true))
    }

    func testOnlyTheActiveDecksUnsavedEditsAreKnownToBeLeftBehind() {
        XCTAssertTrue(SlidesSeenCloseSave.leftUnsaved(span: span(), now: s(saved: false)))
        XCTAssertFalse(SlidesSeenCloseSave.leftUnsaved(span: span(), now: s(saved: true)))
        XCTAssertFalse(SlidesSeenCloseSave.leftUnsaved(span: span(), now: s(path: "/d/b.pptx", deck: "b.pptx", saved: false)))
        XCTAssertFalse(SlidesSeenCloseSave.leftUnsaved(span: span(), now: .gone(at: t0)))
        XCTAssertFalse(SlidesSeenCloseSave.leftUnsaved(span: span(path: "Presentation1"), now: s(path: "Presentation1", saved: false)))
    }

    // MARK: - slide_seen payload

    func testPayloadCarriesTheContract() throws {
        let p = try XCTUnwrap(SlidesSeenEvent.payload(.qualified, span: span(), at: t0))
        XCTAssertEqual(p["type"] as? String, "slide_seen")
        XCTAssertEqual(p["phase"] as? String, "qualified")
        XCTAssertEqual(p["path"] as? String, "/d/a.pptx")
        XCTAssertEqual(p["deck"] as? String, "a.pptx")
        XCTAssertEqual(p["slide_id"] as? Int, 256)
        XCTAssertEqual(p["slide"] as? Int, 4)
        let at = try XCTUnwrap(p["at"] as? String)
        XCTAssertEqual(ISO8601DateFormatter().date(from: at), t0)
        XCTAssertEqual(SlidesSeenEvent.payload(.closed, span: span(), at: t0)?["phase"] as? String, "closed")
    }

    func testNoPayloadForADeckWithoutAFile() {
        XCTAssertNil(SlidesSeenEvent.payload(.closed, span: span(path: nil), at: t0))
        XCTAssertNil(SlidesSeenEvent.payload(.closed, span: span(path: "Presentation1"), at: t0))
    }

    // MARK: - slide_seen_captured → toast

    func testCapturedMessageReachesTheToastCallback() {
        let server = LocalWebSocketServer()
        let got = expectation(description: "captured")
        server.onSlideSeenCaptured = { deck, slide, updated in
            XCTAssertEqual(deck, "a.pptx"); XCTAssertEqual(slide, 7); XCTAssertTrue(updated)
            got.fulfill()
        }
        server.handleText(#"{"type":"slide_seen_captured","deck":"a.pptx","slide":7,"change":"updated"}"#, from: UUID())
        wait(for: [got], timeout: 1)
    }

    func testToastGlyphAndCorner() {
        XCTAssertEqual(SlideSeenToast.glyph(updated: false), "📷")
        XCTAssertEqual(SlideSeenToast.glyph(updated: true), "📷↻")
        let o = SlideSeenToast.origin(size: NSSize(width: 80, height: 40), visible: NSRect(x: 0, y: 0, width: 1000, height: 600))
        XCTAssertEqual(o, NSPoint(x: 908, y: 548))
    }
}
