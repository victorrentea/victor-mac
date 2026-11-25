import XCTest
@testable import VictorAddons

/// The power rule since 2026-11-03: **AC transcribes, battery only records**,
/// and the menu can switch the battery recording off until the next AC.
///
/// `restartIfShouldBeRunning` exists because a bare stop/start had a failure
/// nobody would ever notice: on battery it started a *full* Whisper, and nothing
/// stopped it again — a 1.8 GB model draining the battery until the charger came
/// back. It must restart in the mode the power source asks for, or not at all.
final class TranscriptionRestartTests: XCTestCase {
    private final class Fake {
        var onAC: Bool
        var running = false
        var events: [String] = []
        init(onAC: Bool) { self.onAC = onAC }
    }

    private let store = UserDefaults(suiteName: "TranscriptionRestartTests")!

    override func setUp() {
        super.setUp()
        store.removePersistentDomain(forName: "TranscriptionRestartTests")
    }

    private func make(_ fake: Fake) -> TranscriptionController {
        let c = TranscriptionController(isOnAC: { fake.onAC },
                                        isWhisperRunning: { fake.running },
                                        switchDelay: 0.01,
                                        store: store)
        c.onStart = { mode in
            fake.events.append(mode == .full ? "start full" : mode == .sentinel ? "start listen" : "start capture")
            fake.running = true
        }
        c.onStop = { fake.events.append("stop"); fake.running = false }
        return c
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testARestartOnBatteryKeepsTheRecordingStopped() {
        let fake = Fake(onAC: false)
        let before = make(fake)
        before.setBatteryChoice(.off)
        spin()
        XCTAssertEqual(before.batteryChoice, .off)
        XCTAssertEqual(make(fake).batteryChoice, .off)
    }

    func testARestartOnTheChargerForgetsTheStop() {
        let fake = Fake(onAC: false)
        let before = make(fake)
        before.setBatteryChoice(.off)
        spin()
        XCTAssertEqual(before.batteryChoice, .off)
        fake.onAC = true
        XCTAssertEqual(make(fake).batteryChoice, .listen)
        fake.onAC = false
        XCTAssertEqual(make(fake).batteryChoice, .listen)
    }

    func testTheRuleItself() {
        XCTAssertEqual(TranscriptionController.desiredMode(onAC: true, choice: .off), .full)
        XCTAssertEqual(TranscriptionController.desiredMode(onAC: false, choice: .record), .captureOnly)
        XCTAssertEqual(TranscriptionController.desiredMode(onAC: false, choice: .listen), .sentinel)
        XCTAssertNil(TranscriptionController.desiredMode(onAC: false, choice: .off))
    }

    func testUnpluggingSwitchesAFullWhisperToTheListener() {
        let fake = Fake(onAC: true)
        let c = make(fake)
        var states: [TranscriptionController.State] = []
        c.onStateChanged = { states.append($0) }
        c.start(); spin()
        fake.onAC = false
        c.powerDidChange(); spin()
        XCTAssertEqual(fake.events, ["start full", "stop", "start listen"])
        XCTAssertEqual(states, [.onAC, .listeningOnBattery], "records only once voice is heard (2026-11-25)")
    }

    func testPluggingInTranscribesAgainAndResetsTheMenuSwitch() {
        let fake = Fake(onAC: false)
        let c = make(fake)
        c.start(); spin()
        c.setBatteryChoice(.off); spin()
        XCTAssertEqual(fake.events, ["start listen", "stop"])
        XCTAssertFalse(fake.running)

        fake.onAC = true
        c.powerDidChange(); spin()
        XCTAssertEqual(fake.events.last, "start full")
        XCTAssertEqual(c.batteryChoice, .listen, "the charger resets the menu's stop")

        fake.onAC = false
        c.powerDidChange(); spin()
        XCTAssertEqual(fake.events.last, "start listen", "the next unplugging listens again")
    }

    func testTheMenuSwitchDoesNothingOnAC() {
        let fake = Fake(onAC: true)
        let c = make(fake)
        c.start(); spin()
        c.setBatteryChoice(.off); spin()
        XCTAssertEqual(fake.events, ["start full"])
        XCTAssertEqual(c.batteryChoice, .listen)
    }

    func testRestartOnBatteryComesBackListening() {
        let fake = Fake(onAC: false)
        fake.running = true
        let c = make(fake)
        var started: [TranscriptionController.Mode] = []
        let done = expectation(description: "restarted")
        c.restartIfShouldBeRunning(stop: { fake.running = false },
                                   start: { started.append($0); done.fulfill() },
                                   delay: 0.01)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(started, [.sentinel], "never a full whisper on battery")
    }

    func testRestartWithBatteryRecordingOffOnlyStops() {
        let fake = Fake(onAC: false)
        let c = make(fake)
        c.start(); spin()
        c.setBatteryChoice(.off); spin()
        fake.running = true  // something started it behind our back
        var started = false
        var stopped = false
        c.restartIfShouldBeRunning(stop: { stopped = true }, start: { _ in started = true }, delay: 0.01)
        spin(0.2)
        XCTAssertTrue(stopped)
        XCTAssertFalse(started)
    }
}

/// 👂 2026-11-24: the pill's Stop ❌ cost a whole meeting, so it only stopped the
/// disk; since 2026-11-25 listening is where every unplugging starts. Whisper
/// records once voice is heard, without a restart.
final class BatterySentinelTests: XCTestCase {
    private final class Fake {
        var onAC = false
        var running = false
        var events: [String] = []
    }

    private let store = UserDefaults(suiteName: "BatterySentinelTests")!

    override func setUp() {
        super.setUp()
        store.removePersistentDomain(forName: "BatterySentinelTests")
    }

    private func make(_ fake: Fake) -> TranscriptionController {
        let c = TranscriptionController(isOnAC: { fake.onAC }, isWhisperRunning: { fake.running },
                                        switchDelay: 0.01, store: store)
        c.onStart = { mode in
            fake.events.append(mode == .full ? "start full" : mode == .sentinel ? "start listen" : "start capture")
            fake.running = true
        }
        c.onStop = { fake.events.append("stop"); fake.running = false }
        return c
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testOnBatteryItStartsListening() {
        let fake = Fake()
        let c = make(fake)
        c.start(); spin()
        XCTAssertEqual(fake.events, ["start listen"])
        XCTAssertEqual(c.state, .listeningOnBattery)
    }

    func testVoiceHeardRecordsAgainWithoutARestart() {
        let fake = Fake()
        let c = make(fake)
        var woke: [String] = []
        var states: [TranscriptionController.State] = []
        c.onSentinelWake = { woke.append($0) }
        c.onStateChanged = { states.append($0) }
        c.start(); spin()
        c.setBatteryChoice(.listen); spin()
        fake.events.removeAll()
        c.sentinelWoke("voice:Victor"); spin()
        XCTAssertEqual(fake.events, [], "a restart would throw away the 10 minutes in memory")
        XCTAssertEqual(c.runningMode, .captureOnly)
        XCTAssertEqual(c.state, .recordingOnBattery)
        XCTAssertEqual(woke, ["voice:Victor"])
        XCTAssertEqual(states.last, .recordingOnBattery)
    }

    func testAWakeIsIgnoredUnlessListening() {
        let fake = Fake()
        let c = make(fake)
        var woke = 0
        c.onSentinelWake = { _ in woke += 1 }
        c.start(); spin()
        c.setBatteryChoice(.off); spin()
        c.sentinelWoke("voice:Victor"); spin()
        XCTAssertEqual(c.state, .pausedOnBattery, "the menu's off is not overruled by a late line")
        XCTAssertEqual(woke, 0)
    }

    func testRecordNowFromTheMenuWakesTheListenerInPlace() {
        let fake = Fake()
        let c = make(fake)
        var asked = 0
        c.wakeSentinel = { asked += 1; return true }
        c.start(); spin()
        c.setBatteryChoice(.listen); spin()
        fake.events.removeAll()
        c.setBatteryChoice(.record); spin()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(fake.events, [], "SIGUSR1, not a restart")
        XCTAssertEqual(c.state, .recordingOnBattery)
    }

    func testListeningSurvivesARestartAndTheChargerForgetsIt() {
        let fake = Fake()
        let first = make(fake)
        first.setBatteryChoice(.listen); spin()
        XCTAssertEqual(make(fake).batteryChoice, .listen)
        fake.onAC = true
        XCTAssertEqual(make(fake).batteryChoice, .listen)
    }

    func testAnExplicitRecordSurvivesARestart() {
        let fake = Fake()
        let first = make(fake)
        first.setBatteryChoice(.record); spin()
        XCTAssertEqual(make(fake).batteryChoice, .record)
    }

    func testTheOldStoppedFlagReadsAsOff() {
        store.set(true, forKey: "TranscriptionController.batteryRecordingStopped")
        XCTAssertEqual(make(Fake()).batteryChoice, .off)
    }

    func testTheMenuOffersOffOnlyThere() {
        typealias M = MenuBarManager.BatteryRecordingMenu
        XCTAssertEqual(M.rows(.onAC).map(\.choice), [])
        XCTAssertEqual(M.rows(.recordingOnBattery).map(\.choice), [.off])
        XCTAssertEqual(M.rows(.listeningOnBattery).map(\.choice), [.record, .off])
        XCTAssertEqual(M.rows(.pausedOnBattery).map(\.choice), [.listen])
    }
}

final class BannerBlinkTests: XCTestCase {
    func testTheBlinkIsDiscreteAndForever() {
        let blink = BottomLeftBanner.blinkAnimation()
        XCTAssertEqual(blink.calculationMode, .discrete, "no 60 Hz fade")
        XCTAssertEqual(blink.duration, 2)
        XCTAssertEqual(blink.repeatCount, .infinity)
        XCTAssertFalse(blink.isRemovedOnCompletion)
    }
}

final class MicOverlayTests: XCTestCase {
    /// The mark sits beside the microphone, never over it (2026-11-25).
    func testTheMarkGetsItsOwnColumn() {
        XCTAssertEqual(MicOverlay.canvas(.none), NSSize(width: 18, height: 18))
        XCTAssertEqual(MicOverlay.canvas(.recording), NSSize(width: 31, height: 18))
        XCTAssertEqual(MicOverlay.canvas(.pause(lit: true)), NSSize(width: 31, height: 18))
        XCTAssertEqual(MicOverlay.canvas(.pause(lit: false)), NSSize(width: 31, height: 18),
                       "the dark half of the blink keeps the column")
    }

    /// The 🎙️ menu's top row says the mark in words, and only off AC (2026-11-25).
    func testTheMenuSaysWhatTheMarkMeans() {
        typealias M = MenuBarManager.BatteryRecordingMenu
        XCTAssertNil(M.status(.onAC))
        XCTAssertTrue(M.status(.recordingOnBattery)!.hasPrefix("🟠"))
        XCTAssertTrue(M.status(.listeningOnBattery)!.hasPrefix("🟥"))
        XCTAssertTrue(M.status(.pausedOnBattery)!.hasPrefix("🟥"))
    }

    /// 🟠 steady while recording on battery, 🟥 blinking while paused (2026-11-25).
    func testTheMarksAreTheTwoEmoji() {
        XCTAssertEqual(MicOverlay.emoji(.recording), "🟠")
        XCTAssertEqual(MicOverlay.emoji(.pause(lit: true)), "🟥")
        XCTAssertNil(MicOverlay.emoji(.pause(lit: false)))
        XCTAssertNil(MicOverlay.emoji(.none))
    }
}

final class BannerButtonOrderTests: XCTestCase {
    /// `Send` is always the upper button; the countdown still fills the auto one.
    func testSendIsAlwaysOnTop() {
        XCTAssertFalse(BottomLeftBanner.autoOnTop(click: .send), "Discard auto, Send click → Send on top")
        XCTAssertTrue(BottomLeftBanner.autoOnTop(click: .cancel), "Send auto, Cancel click → Send on top")
        XCTAssertTrue(BottomLeftBanner.autoOnTop(click: .stopUntilAC))
    }
}
