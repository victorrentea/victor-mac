import XCTest
@testable import VictorAddons

final class PowerPointSavedBadgeTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day,
                                           hour: hour, minute: minute, second: second))!
    }

    private func text(_ saved: Date, unsaved: Bool = false, by: PowerPointSavedBadgePolicy.SavedBy = .unknown,
                      now: Date) -> String {
        PowerPointSavedBadgePolicy.text(savedAt: saved, unsaved: unsaved, by: by, now: now, calendar: calendar)
    }

    // MARK: - who saved

    func testSaysWhetherTheSaveWasAnAutoSaveOrHis() {
        XCTAssertEqual(text(date(5, 18, 16), by: .auto, now: date(5, 18, 20)), "✓ Auto-saved · 18:16")
        XCTAssertEqual(text(date(5, 18, 16), by: .you, now: date(5, 18, 20)), "✓ Saved by you · 18:16")
    }

    func testAnUnsavedDeckSaysWhoMadeTheLastSave() {
        XCTAssertEqual(text(date(5, 18, 16), unsaved: true, by: .auto, now: date(5, 18, 20)),
                       "● Unsaved · auto-saved 18:16")
        XCTAssertEqual(text(date(5, 18, 16), unsaved: true, by: .you, now: date(5, 18, 20)),
                       "● Unsaved · saved by you 18:16")
    }

    func testASaveTheLogClaimsIsAnAutoSaveAnyOtherIsHis() {
        let saved = date(5, 18, 16)
        let ours: [String: Any] = ["started": saved.timeIntervalSince1970 - 0.4, "mtime": saved.timeIntervalSince1970]
        XCTAssertEqual(PowerPointSavedBadgePolicy.savedBy(entry: ours, savedAt: saved, now: date(5, 18, 20)), .auto)
        // ⌘S two minutes after that auto-save: the log still holds the older one.
        XCTAssertEqual(PowerPointSavedBadgePolicy.savedBy(entry: ours, savedAt: date(5, 18, 18), now: date(5, 18, 20)), .you)
        XCTAssertEqual(PowerPointSavedBadgePolicy.savedBy(entry: nil, savedAt: saved, now: date(5, 18, 20)), .you)
    }

    /// The log keeps a day: a deck last saved before that may have been saved by either.
    func testASaveOlderThanTheLogIsNotAttributed() {
        XCTAssertEqual(PowerPointSavedBadgePolicy.savedBy(entry: nil, savedAt: date(3, 22, 43), now: date(5, 10, 0)), .unknown)
    }

    func testSavedDeckSaysSoAndShowsNoAge() {
        XCTAssertEqual(text(date(5, 19, 21), now: date(5, 19, 56)), "✓ Saved · 19:21")
    }

    func testUnsavedDeckSaysSoAndWhenItLastReachedTheDisk() {
        XCTAssertEqual(text(date(5, 19, 21), unsaved: true, now: date(5, 19, 56)),
                       "● Unsaved · last save 19:21")
    }

    func testSavedOnAnotherDayShowsTheDate() {
        XCTAssertEqual(text(date(3, 22, 43), now: date(5, 10, 0)), "✓ Saved · 3 Nov 22:43")
    }

    func testUnsavedOnAnotherDayShowsTheDate() {
        XCTAssertEqual(text(date(3, 22, 43), unsaved: true, now: date(5, 10, 0)),
                       "● Unsaved · last save 3 Nov 22:43")
    }

    func testCenteredOnTheStatusBarOfTheWindow() {
        // AX: window 1000 wide at x=100, bottom edge at y=900 on a 1117 pt tall primary screen.
        let origin = PowerPointSavedBadgePolicy.origin(
            window: CGRect(x: 100, y: 100, width: 1000, height: 800),
            badge: CGSize(width: 120, height: 18), primaryScreenHeight: 1117)
        XCTAssertEqual(origin, CGPoint(x: 540, y: 221))
    }
}
