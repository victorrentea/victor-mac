import Foundation

/// Dead-simple transcription lifecycle.
///
/// The rule is: **on AC, Whisper transcribes; on battery, it only records**
/// (since 2026-11-03 — before that it stopped outright, and an important meeting
/// taken on battery left no trace at all). In `.captureOnly` the microphones stay
/// open and each channel goes to `battery-audio/` without the 1.8 GB model ever
/// being loaded; the full process that starts on AC transcribes that audio and
/// slots it into the day's transcript at the minute it was spoken
/// (`whisper-transcribe/battery_audio.py`).
///
/// On battery there are three choices (`BatteryChoice`), all reset by the
/// charger (to `batteryDefault`) and all surviving a restart of this app:
/// - `listen` — **the default since 2026-11-25** (it was the on-battery pill's
///   `Stop ❌` from 2026-11-24). Nothing reaches the disk, but whisper keeps
///   listening, holds the last 10 min in memory and, on 30 s of voice in 2 min
///   or a call starting, writes them out and records by itself
///   (`SENTINEL_WAKE`, `sentinelWoke()`). Victor: *"înregistrezi dacă simți că
///   e voce în jur"* — and no pill about it (`BatteryRecordingNotice` is gone).
/// - `record` — the microphones go to disk from the first second (menu's
///   `Record now`, or a wake).
/// - `off` — only from the menu: nothing at all, for the case where the noise
///   around fools the listener (a plane).
///
/// A 60s heartbeat restarts Whisper, in whichever mode the power source asks
/// for, if it died (crash, OOM, the capture-stall watchdog's exit).
///
/// There is deliberately no rule here based on the transcript going quiet —
/// silence cannot tell a dead microphone from an empty room, and it used to
/// restart Whisper every 10 minutes all night.
final class TranscriptionController {
    enum Mode: Equatable {
        /// On AC: live transcription (and the battery backlog, if any).
        case full
        /// On battery: record only, no model.
        case captureOnly
        /// On battery after `Stop ❌`: listen only, no model, no disk — until
        /// voice is heard, when the same process turns into `captureOnly`.
        case sentinel
    }

    enum BatteryChoice: String {
        case record, listen, off
    }

    /// What every unplugging starts with.
    static let batteryDefault: BatteryChoice = .listen

    enum State: Equatable {
        case onAC
        case recordingOnBattery
        /// On battery after `Stop ❌`: listening for voice to record again.
        case listeningOnBattery
        /// On battery with everything switched off from the menu.
        case pausedOnBattery
    }

    /// Start Whisper in `Mode`. Always invoked on the main queue.
    var onStart: ((Mode) -> Void)?
    /// Stop Whisper. Always invoked on the main queue.
    var onStop: (() -> Void)?
    /// Reports the high-level state on every change. Main queue.
    var onStateChanged: ((State) -> Void)?
    /// Fired when the heartbeat brings Whisper back after an unexpected death
    /// (distinct from a deliberate power-on start). Main queue.
    var onAutoRestart: ((Mode) -> Void)?
    /// 👂 The listener heard voice (or a call) and is recording again. Main
    /// queue, just before the state change.
    var onSentinelWake: ((String) -> Void)?
    /// Tell a listening whisper to record now without a restart; false when it
    /// could not be told (then it is restarted in `captureOnly`, ring lost).
    var wakeSentinel: (() -> Bool)?

    private let isOnAC: () -> Bool
    private let isWhisperRunning: () -> Bool
    private let switchDelay: TimeInterval
    private let store: UserDefaults
    /// The bool of 2026-11-06 (`true` = stopped); read once, as `off`, then gone.
    private static let legacyStoppedKey = "TranscriptionController.batteryRecordingStopped"
    private static let choiceKey = "TranscriptionController.batteryChoice"
    private var heartbeat: DispatchSourceTimer?
    private let queue = DispatchQueue(
        label: "ro.victorrentea.macos-addons.transcription-controller", qos: .utility)

    /// Main-queue state.
    private(set) var runningMode: Mode?
    /// What to do on battery. Reset by the charger.
    private(set) var batteryChoice: BatteryChoice {
        didSet {
            if batteryChoice == Self.batteryDefault { store.removeObject(forKey: Self.choiceKey) }
            else { store.set(batteryChoice.rawValue, forKey: Self.choiceKey) }
        }
    }
    private var lastReportedState: State?

    init(isOnAC: @escaping () -> Bool = { PowerMonitor.isOnAC() },
         isWhisperRunning: @escaping () -> Bool,
         switchDelay: TimeInterval = 1.5,
         store: UserDefaults = .standard) {
        self.isOnAC = isOnAC
        self.isWhisperRunning = isWhisperRunning
        self.switchDelay = switchDelay
        self.store = store
        var saved = store.string(forKey: Self.choiceKey).flatMap(BatteryChoice.init(rawValue:))
        if store.bool(forKey: Self.legacyStoppedKey) { saved = saved ?? .off }
        store.removeObject(forKey: Self.legacyStoppedKey)
        batteryChoice = isOnAC() ? Self.batteryDefault : (saved ?? Self.batteryDefault)
        // `didSet` does not run in init: starting on AC must forget it here.
        if isOnAC() { store.removeObject(forKey: Self.choiceKey) }
    }

    /// What should be running right now, if anything.
    static func desiredMode(onAC: Bool, choice: BatteryChoice) -> Mode? {
        if onAC { return .full }
        switch choice {
        case .record: return .captureOnly
        case .listen: return .sentinel
        case .off: return nil
        }
    }

    static func state(onAC: Bool, choice: BatteryChoice) -> State {
        if onAC { return .onAC }
        switch choice {
        case .record: return .recordingOnBattery
        case .listen: return .listeningOnBattery
        case .off: return .pausedOnBattery
        }
    }

    var desiredMode: Mode? { Self.desiredMode(onAC: isOnAC(), choice: batteryChoice) }

    var state: State { Self.state(onAC: isOnAC(), choice: batteryChoice) }

    /// Call once on launch: applies the current power state and arms the
    /// heartbeat.
    func start() {
        DispatchQueue.main.async { [weak self] in self?.apply() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.heartbeatTick() }
        }
        t.resume()
        heartbeat = t
    }

    /// Call from PowerMonitor's AC/battery callbacks.
    func powerDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Plugging in resets the battery choice: the next unplugging listens.
            if self.isOnAC() { self.batteryChoice = Self.batteryDefault }
            self.apply()
        }
    }

    /// The menu's rows. Only meaningful on
    /// battery; on AC it is a no-op, since the charger resets it anyway.
    func setBatteryChoice(_ choice: BatteryChoice) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isOnAC() else { return }
            if choice == .record, self.batteryChoice == .listen, self.runningMode == .sentinel,
               self.isWhisperRunning(), self.wakeSentinel?() == true {
                // Its SENTINEL_WAKE:menu arrives next and is ignored, the
                // choice being `record` already.
                self.batteryChoice = .record
                self.runningMode = .captureOnly
                self.apply()
                return
            }
            self.batteryChoice = choice
            self.apply()
        }
    }

    /// 👂 Whisper's `SENTINEL_WAKE:<why>`: the listening process has already
    /// written its ring out and is recording — so the state moves to
    /// `recordingOnBattery` **without** a restart (a restart would lose the
    /// ring). Ignored unless we are listening. Main queue.
    func sentinelWoke(_ why: String) {
        guard !isOnAC(), batteryChoice == .listen else { return }
        batteryChoice = .record
        if runningMode == .sentinel { runningMode = .captureOnly }
        onSentinelWake?(why)
        apply()
    }

    /// Re-launch Whisper so it picks up changed launch settings — in the mode
    /// the power rule asks for, or not at all.
    ///
    /// Callers used to do this themselves, with a bare `stop()` then `start()`.
    /// On battery that started a *full* Whisper that nothing ever stopped again,
    /// a 1.8 GB model draining the battery until the charger came back.
    func restartIfShouldBeRunning(stop: @escaping () -> Void,
                                  start: @escaping (Mode) -> Void,
                                  delay: TimeInterval = 1.5) {
        guard let mode = desiredMode else {
            if isWhisperRunning() { stop() }
            runningMode = nil
            return
        }
        stop()
        runningMode = mode
        // PortAudio needs a beat to release the devices before the replacement
        // grabs them, or the new process inherits the same mess.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { start(mode) }
    }

    /// Sync Whisper to the current power source and menu switch. Main queue.
    private func apply() {
        let s = state
        if s != lastReportedState {
            lastReportedState = s
            onStateChanged?(s)
        }
        let want = desiredMode
        let running = isWhisperRunning()
        if want == nil {
            if running { onStop?() }
            runningMode = nil
            return
        }
        if running && runningMode == want { return }
        if running {
            // Wrong mode: stop, give PortAudio its beat, start the right one.
            onStop?()
            runningMode = want
            DispatchQueue.main.asyncAfter(deadline: .now() + switchDelay) { [weak self] in
                guard let self, self.desiredMode == want else { return }
                if !self.isWhisperRunning() { self.onStart?(want!) }
            }
        } else {
            runningMode = want
            onStart?(want!)
        }
    }

    /// Start Whisper now if it should be running and is not — the wake path,
    /// which must not wait up to a minute for the heartbeat. Main queue.
    func ensureRunning() {
        guard let want = desiredMode, !isWhisperRunning() else { return }
        runningMode = want
        onStart?(want)
    }

    /// Heartbeat: bring Whisper back if it died, in the mode it should be in.
    private func heartbeatTick() {
        guard let want = desiredMode, !isWhisperRunning() else { return }
        runningMode = want
        onStart?(want)
        onAutoRestart?(want)
    }
}
