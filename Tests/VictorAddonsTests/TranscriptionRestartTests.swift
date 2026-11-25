import XCTest
@testable import VictorAddons

/// Since 2026-11-25 **three choices on any power source** — 🟢 transcribe, 🟠 listen/record,
/// 🟥 off — and each change of power source resets them: AC to 🟢, battery to 🟠 listening.
///
/// `restartIfShouldBeRunning` exists because a bare stop/start had a failure
/// nobody would ever notice: on battery it started a *full* Whisper, and nothing
/// stopped it again — a 1.8 GB model draining the battery until the charger came
/// back. It must restart in the mode the choice asks for, or not at all.
final class TranscriptionRestartTests: XCTestCase {
    final class Fake {
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

    func testTheRuleItself() {
        XCTAssertEqual(TranscriptionController.desiredMode(.transcribe), .full)
        XCTAssertEqual(TranscriptionController.desiredMode(.record), .captureOnly)
        XCTAssertEqual(TranscriptionController.desiredMode(.listen), .sentinel)
        XCTAssertNil(TranscriptionController.desiredMode(.off))
    }

    func testEachPowerSourceStartsWithItsDefault() {
        XCTAssertEqual(make(Fake(onAC: true)).choice, .transcribe)
        XCTAssertEqual(make(Fake(onAC: false)).choice, .listen)
    }

    func testARestartKeepsTheChoiceOnTheSamePowerSource() {
        let fake = Fake(onAC: false)
        let onBattery = make(fake)
        onBattery.setChoice(.off); spin()
        XCTAssertEqual(make(fake).choice, .off)
        fake.onAC = true
        let onAC = make(fake)
        onAC.setChoice(.listen); spin()
        XCTAssertEqual(make(fake).choice, .listen, "a choice made on AC survives a restart on AC")
    }

    func testARestartOnTheOtherPowerSourceForgetsTheChoice() {
        let fake = Fake(onAC: false)
        let first = make(fake)
        first.setChoice(.off); spin()
        fake.onAC = true
        XCTAssertEqual(make(fake).choice, .transcribe)
    }

    func testTheOldBatteryKeysAreReadOnce() {
        store.set(true, forKey: "TranscriptionController.batteryRecordingStopped")
        XCTAssertEqual(make(Fake(onAC: false)).choice, .off)
        XCTAssertEqual(make(Fake(onAC: false)).choice, .listen, "gone after the first read")
        store.set("record", forKey: "TranscriptionController.batteryChoice")
        XCTAssertEqual(make(Fake(onAC: false)).choice, .record)
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
        XCTAssertEqual(states, [.transcribing, .listening])
    }

    func testPluggingInResetsAnyChoiceToTranscribing() {
        let fake = Fake(onAC: false)
        let c = make(fake)
        c.start(); spin()
        c.setChoice(.off); spin()
        XCTAssertEqual(fake.events, ["start listen", "stop"])
        fake.onAC = true
        c.powerDidChange(); spin()
        XCTAssertEqual(fake.events.last, "start full")
        XCTAssertEqual(c.choice, .transcribe)
        c.setChoice(.off); spin()
        fake.onAC = false
        c.powerDidChange(); spin()
        XCTAssertEqual(fake.events.last, "start listen", "unplugging resets to 🟠 listening")
    }

    func testOnACTheMenuCanRecordOrStop() {
        let fake = Fake(onAC: true)
        let c = make(fake)
        c.start(); spin()
        c.setChoice(.listen); spin()
        XCTAssertEqual(fake.events, ["start full", "stop", "start listen"])
        c.setChoice(.off); spin()
        XCTAssertEqual(fake.events.last, "stop")
        XCTAssertFalse(fake.running)
        XCTAssertEqual(c.state, .stopped)
    }

    func testOnBatteryTheMenuCanTranscribe() {
        let fake = Fake(onAC: false)
        let c = make(fake)
        c.start(); spin()
        c.setChoice(.transcribe); spin()
        XCTAssertEqual(fake.events, ["start listen", "stop", "start full"])
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
        XCTAssertEqual(started, [.sentinel], "never a full whisper on battery unless picked")
    }

    func testRestartWhenStoppedOnlyStops() {
        let fake = Fake(onAC: true)
        let c = make(fake)
        c.start(); spin()
        c.setChoice(.off); spin()
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
    private typealias Fake = TranscriptionRestartTests.Fake

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
        let fake = Fake(onAC: false)
        let c = make(fake)
        c.start(); spin()
        XCTAssertEqual(fake.events, ["start listen"])
        XCTAssertEqual(c.state, .listening)
    }

    func testVoiceHeardRecordsAgainWithoutARestart() {
        let fake = Fake(onAC: false)
        let c = make(fake)
        var woke: [String] = []
        var states: [TranscriptionController.State] = []
        c.onSentinelWake = { woke.append($0) }
        c.onStateChanged = { states.append($0) }
        c.start(); spin()
        fake.events.removeAll()
        c.sentinelWoke("voice:Victor"); spin()
        XCTAssertEqual(fake.events, [], "a restart would throw away the 10 minutes in memory")
        XCTAssertEqual(c.runningMode, .captureOnly)
        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(woke, ["voice:Victor"])
        XCTAssertEqual(states.last, .recording)
    }

    func testAWakeIsIgnoredUnlessListening() {
        let fake = Fake(onAC: false)
        let c = make(fake)
        var woke = 0
        c.onSentinelWake = { _ in woke += 1 }
        c.start(); spin()
        c.setChoice(.off); spin()
        c.sentinelWoke("voice:Victor"); spin()
        XCTAssertEqual(c.state, .stopped, "the menu's 🟥 is not overruled by a late line")
        XCTAssertEqual(woke, 0)
    }

    func testRecordFromTheListenerWakesItInPlace() {
        let fake = Fake(onAC: false)
        let c = make(fake)
        var asked = 0
        c.wakeSentinel = { asked += 1; return true }
        c.start(); spin()
        fake.events.removeAll()
        c.setChoice(.record); spin()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(fake.events, [], "SIGUSR1, not a restart")
        XCTAssertEqual(c.state, .recording)
    }

    func testPickingOrangeWhileRecordingKeepsRecording() {
        let fake = Fake(onAC: false)
        let c = make(fake)
        c.start(); spin()
        c.sentinelWoke("voice:Victor"); spin()
        fake.events.removeAll()
        c.setChoice(.listen); spin()
        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(fake.events, [])
    }

    func testARecordingSurvivesARestart() {
        let fake = Fake(onAC: false)
        let first = make(fake)
        first.setChoice(.record); spin()
        XCTAssertEqual(make(fake).choice, .record)
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
    /// No column beside the mic any more: the state is its colour (2026-11-25).
    func testTheIconIsJustTheMic() {
        for overlay in [MicOverlay.none, .recording, .pause(lit: true), .pause(lit: false)] {
            XCTAssertEqual(MicOverlay.canvas(overlay), NSSize(width: 18, height: 18))
        }
    }

    /// Three rows, each wearing the mark the bar shows in its state, the one in force
    /// ticked; 🟠 covers listening as well as recording (2026-11-25).
    func testTheMenuRowsAndTheirTicks() {
        typealias M = MenuBarManager.TranscriptionMenu
        XCTAssertEqual(M.rows.map(\.title), ["🟢 Transcribing", "🟠 Recording audio", "🟥 Stopped"])
        XCTAssertEqual(M.ticked(.transcribing), .transcribe)
        XCTAssertEqual(M.ticked(.listening), .listen)
        XCTAssertEqual(M.ticked(.recording), .listen)
        XCTAssertEqual(M.ticked(.stopped), .off)
        XCTAssertEqual(M.tooltip(.recording), "Recording for later transcribing")
    }

    /// Orange steady while recording or listening, red blinking while stopped, the bar's
    /// own ink while transcribing (2026-11-25).
    func testTheMicTakesTheStateColour() {
        XCTAssertEqual(MicOverlay.ink(.none, dark: true), .white)
        XCTAssertEqual(MicOverlay.ink(.none, dark: false), .black)
        XCTAssertEqual(MicOverlay.ink(.recording, dark: true), .systemOrange)
        XCTAssertEqual(MicOverlay.ink(.pause(lit: true), dark: true), .systemRed)
        XCTAssertEqual(MicOverlay.ink(.pause(lit: false), dark: true), .white, "the dark half of the blink")
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
