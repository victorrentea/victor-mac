import AppKit
import XCTest
@testable import VictorAddons

final class BrainEnergyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testFullRightAfterTheBreak() {
        XCTAssertEqual(BrainEnergy.state(reference: t0, now: t0),
                       .draining(level: 1, remaining: 75 * 60))
    }

    func testHalfwayAfterThirtySevenAndAHalfMinutes() {
        guard case let .draining(level, _) = BrainEnergy.state(reference: t0, now: t0 + 37.5 * 60) else {
            return XCTFail("should still be draining")
        }
        XCTAssertEqual(level, 0.5, accuracy: 0.0001)
    }

    func testEmptyAtOneHourFifteenAndCountsTheOverdue() {
        XCTAssertEqual(BrainEnergy.state(reference: t0, now: t0 + 75 * 60), .depleted(overdue: 0))
        XCTAssertEqual(BrainEnergy.state(reference: t0, now: t0 + 90 * 60), .depleted(overdue: 15 * 60))
    }

    /// After lunch the battery lasts an hour; after a coffee break, or a refill
    /// after lunch, the usual 75 min.
    func testAfterLunchItLastsOnlyAnHour() {
        XCTAssertTrue(BrainEnergy.isLunch(breakStartedAt: t0 - 60 * 60, endedAt: t0))
        XCTAssertTrue(BrainEnergy.isLunch(breakStartedAt: t0 - 30 * 60, endedAt: t0))
        XCTAssertFalse(BrainEnergy.isLunch(breakStartedAt: t0 - 15 * 60, endedAt: t0))
        XCTAssertFalse(BrainEnergy.isLunch(breakStartedAt: nil, endedAt: t0))

        let afterLunch = BrainEnergy.span(reference: t0, lunchEndedAt: t0)
        XCTAssertEqual(afterLunch, 60 * 60)
        XCTAssertEqual(BrainEnergy.state(reference: t0, now: t0 + 60 * 60, span: afterLunch), .depleted(overdue: 0))
        XCTAssertEqual(BrainEnergy.span(reference: t0 + 600, lunchEndedAt: t0), 75 * 60)   // refilled since
        XCTAssertEqual(BrainEnergy.span(reference: t0, lunchEndedAt: nil), 75 * 60)
    }

    func testNoReferenceIsIdle() {
        XCTAssertEqual(BrainEnergy.state(reference: nil, now: t0), .idle)
    }

    /// Three hours after the last break the battery hides, until the next one ends.
    func testThreeHoursAfterTheBreakItGoesIdle() {
        XCTAssertNotNil(BrainEnergy.reference(breakEndedAt: t0 - 3 * 3600 + 60, refilledAt: nil, now: t0))
        XCTAssertNil(BrainEnergy.reference(breakEndedAt: t0 - 3 * 3600 - 60, refilledAt: nil, now: t0))
        XCTAssertEqual(BrainEnergy.state(reference: nil, now: t0), .idle)
    }

    /// A manual refill and a break end: whichever happened last filled the battery.
    func testTheLaterOfBreakEndAndRefillWins() {
        XCTAssertEqual(BrainEnergy.reference(breakEndedAt: t0 - 600, refilledAt: t0 - 60, now: t0), t0 - 60)
        XCTAssertEqual(BrainEnergy.reference(breakEndedAt: t0 - 60, refilledAt: t0 - 600, now: t0), t0 - 60)
    }

    func testAFutureReferenceIsIgnored() {
        XCTAssertNil(BrainEnergy.reference(breakEndedAt: t0 + 600, refilledAt: nil, now: t0))
        XCTAssertNil(BrainEnergy.reference(breakEndedAt: nil, refilledAt: t0 + 31 * 60, now: t0))
    }

    /// A session started at 8:47 drains from 9:00; at 9:12 from 9:30; at 9:00 sharp from 9:00.
    func testSessionStartsDrainingAtTheNextHalfHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: h, minute: m, second: s))!
        }
        XCTAssertEqual(BrainEnergy.sessionStart(startedAt: at(8, 47), calendar: cal), at(9, 0))
        XCTAssertEqual(BrainEnergy.sessionStart(startedAt: at(9, 12, 30), calendar: cal), at(9, 30))
        XCTAssertEqual(BrainEnergy.sessionStart(startedAt: at(9, 0), calendar: cal), at(9, 0))
        XCTAssertEqual(BrainEnergy.sessionStart(startedAt: at(9, 59, 59), calendar: cal), at(10, 0))
    }

    /// Until the scheduled start the battery waits full and says when it starts.
    func testFullUntilTheScheduledStart() {
        let start = t0 + 13 * 60
        let ref = BrainEnergy.reference(breakEndedAt: t0 - 3600, refilledAt: start, now: t0)
        XCTAssertEqual(ref, start)
        let state = BrainEnergy.state(reference: ref, now: t0)
        XCTAssertEqual(state, .draining(level: 1, remaining: 75 * 60))
        XCTAssertEqual(BrainEnergy.lines(state, reference: ref, now: t0)[2], "🕒 starts in ~13 minutes")
    }

    /// Hide holds until something newer than the click refills the battery.
    func testHideLastsUntilTheNextBreak() {
        let draining = BrainEnergy.State.draining(level: 0.5, remaining: 1800)
        XCTAssertTrue(BrainEnergy.isShown(draining, reference: t0, hiddenAt: nil))
        XCTAssertFalse(BrainEnergy.isShown(draining, reference: t0, hiddenAt: t0 + 60))
        XCTAssertTrue(BrainEnergy.isShown(draining, reference: t0 + 120, hiddenAt: t0 + 60))
        XCTAssertFalse(BrainEnergy.isShown(.idle, reference: nil, hiddenAt: nil))
    }

    func testDescriptions() {
        XCTAssertEqual(BrainEnergy.describe(.draining(level: 0.21, remaining: 10 * 60)), "🔋 left: ~10 minutes (21%)")
        XCTAssertEqual(BrainEnergy.describe(.draining(level: 0.02, remaining: 60)), "🪫 left: ~1 minute (2%)")
        XCTAssertEqual(BrainEnergy.describe(.depleted(overdue: 10 * 60)), "☢️ depleted: 10 min ago")
        XCTAssertEqual(BrainEnergy.describe(.depleted(overdue: 20)), "☢️ depleted: just now")
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(BrainEnergy.lines(.draining(level: 0.21, remaining: 10 * 60),
                                         reference: now.addingTimeInterval(-40 * 60), now: now),
                       ["🧠 Brain Stamina", "🔋 left: ~10 minutes (21%)", "🕒 started: 40 min ago"])
        XCTAssertEqual(BrainEnergy.lines(.depleted(overdue: 10 * 60),
                                         reference: now.addingTimeInterval(-85 * 60), now: now),
                       ["🧠 Brain Stamina", "☢️ depleted: 10 min ago", "🕒 started: 1h 25m ago"])
        XCTAssertEqual(BrainEnergy.minutes(75 * 60), "1h 15m")
    }

    /// Green down to half, yellow down to 15%, red below, blinking at 5% or less.
    func testChargeColourByLevel() {
        func charge(_ level: Double) -> BrainEnergy.Charge { BrainEnergy.charge(.draining(level: level, remaining: 60)) }
        XCTAssertEqual(charge(1), .green)
        XCTAssertEqual(charge(0.5), .green)
        XCTAssertEqual(charge(0.49), .yellow)
        XCTAssertEqual(charge(0.16), .yellow)
        XCTAssertEqual(charge(0.15), .red)
        XCTAssertEqual(charge(0.06), .red)
        XCTAssertEqual(charge(0.05), .blinkingRed)
        XCTAssertEqual(BrainEnergy.charge(.depleted(overdue: 0)), .blinkingRed)
    }

    func testShowBrainBatteryIsOnByDefault() {
        let saved = UserDefaults.standard.object(forKey: BrainBatterySettings.enabledKey)
        defer { UserDefaults.standard.set(saved, forKey: BrainBatterySettings.enabledKey) }
        UserDefaults.standard.removeObject(forKey: BrainBatterySettings.enabledKey)
        XCTAssertTrue(BrainBatterySettings.isEnabled)
    }

    /// `BRAIN_BATTERY_RENDER=<dir> swift test --filter BrainEnergyTests` writes
    /// every state, dark and light, at 4× — to look at the drawing without a menu bar.
    func testRenderSamplesWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["BRAIN_BATTERY_RENDER"] else { return }
        let samples: [(String, BrainEnergy.State, Bool)] = [
            ("100", .draining(level: 1, remaining: 4500), true),
            ("62", .draining(level: 0.62, remaining: 1700), true),
            ("40", .draining(level: 0.40, remaining: 1800), true),
            ("12", .draining(level: 0.12, remaining: 540), true),
            ("04-on", .draining(level: 0.04, remaining: 180), true),
            ("04-off", .draining(level: 0.04, remaining: 180), false),
            ("empty-on", .depleted(overdue: 120), true),
            ("empty-off", .depleted(overdue: 120), false),
            ("idle", .idle, true),
        ]
        let size = BrainBatteryIcon.size, scale: CGFloat = 4
        for (name, state, blink) in samples {
            for dark in [true, false] {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                           pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                    (dark ? NSColor(srgbRed: 0.24, green: 0.45, blue: 0.66, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(origin: .zero, size: size).fill()
                    BrainBatteryIcon.draw(state: state, blinkOn: blink)
                }
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: "\(dir)/brain-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    // MARK: - 📱 The tablet's /ping fragment (2026-11-27)

    func testTabletFieldCarriesSecondsLeftAndLevel() {
        XCTAssertEqual(BrainEnergy.tabletField(.draining(level: 0.4, remaining: 599.2), shown: true),
                       ",\"brainLeftS\":600,\"brainPct\":40")
    }

    func testTabletFieldGoesNegativeOnceDepleted() {
        XCTAssertEqual(BrainEnergy.tabletField(.depleted(overdue: 600), shown: true),
                       ",\"brainLeftS\":-600,\"brainPct\":0")
        XCTAssertEqual(BrainEnergy.tabletField(.depleted(overdue: 0), shown: true),
                       ",\"brainLeftS\":-1,\"brainPct\":0", "dead at once, never a 0 that reads as alive")
    }

    func testTabletFieldIsAbsentWhenTheMenuBarShowsNoBattery() {
        XCTAssertEqual(BrainEnergy.tabletField(.draining(level: 0.4, remaining: 600), shown: false), "")
        XCTAssertEqual(BrainEnergy.tabletField(.idle, shown: true), "")
    }
}
