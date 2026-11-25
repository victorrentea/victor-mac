import Foundation

/// Dead-simple transcription lifecycle.
///
/// **Three choices, picked in the 🎙️ menu on any power source** (2026-11-25, Victor:
/// *"pune de fapt 3 opțiuni: 🟢 Transcribing; 🟠 Recording audio; 🟥 stopped … orice
/// setez, la AC se resetează pe verde"*):
/// - 🟢 `transcribe` — Whisper transcribes live. What plugging in the charger resets to.
/// - 🟠 `listen` / `record` — the microphones without the 1.8 GB model; the audio is
///   transcribed later by the next full process (`whisper-transcribe/battery_audio.py`).
///   `listen` keeps the last 10 min in memory and, on 30 s of voice in 2 min or a call
///   starting, writes them out and records by itself (`SENTINEL_WAKE`, `sentinelWoke()`)
///   — the menu's 🟠 row, and what unplugging resets to. `record` is what it becomes
///   once woken.
/// - 🟥 `off` — nothing at all: for the plane whose noise would keep waking the listener.
///
/// The choice survives a restart of this app, unless the power source changed meanwhile.
/// Before 2026-11-25 the choice existed only on battery, and AC always transcribed.
///
/// A 60s heartbeat restarts Whisper, in whichever mode the choice asks for, if it died
/// (crash, OOM, the capture-stall watchdog's exit).
///
/// There is deliberately no rule here based on the transcript going quiet —
/// silence cannot tell a dead microphone from an empty room, and it used to
/// restart Whisper every 10 minutes all night.
final class TranscriptionController {
    enum Mode: Equatable {
        /// 🟢 Live transcription (and the recorded backlog, if any).
        case full
        /// 🟠 Record only, no model.
        case captureOnly
        /// 🟠 Listen only, no model, no disk — until voice is heard, when the same
        /// process turns into `captureOnly`.
        case sentinel
    }

    enum Choice: String {
        case transcribe, listen, record, off
    }

    /// What plugging in / unplugging resets the choice to.
    static func defaultChoice(onAC: Bool) -> Choice { onAC ? .transcribe : .listen }

    enum State: Equatable {
        /// 🟢
        case transcribing
        /// 🟠 recording to disk.
        case recording
        /// 🟠 listening for voice to record (the last 10 min in memory).
        case listening
        /// 🟥
        case stopped
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
    /// The keys before 2026-11-25, when the choice was battery-only; read once, then gone.
    private static let legacyKeys = ["TranscriptionController.batteryRecordingStopped",
                                     "TranscriptionController.batteryChoice"]
    private static let choiceKey = "TranscriptionController.choice"
    /// The power source the saved choice was made on: `ac` / `battery`.
    private static let choicePowerKey = "TranscriptionController.choicePower"
    private var heartbeat: DispatchSourceTimer?
    private let queue = DispatchQueue(
        label: "ro.victorrentea.macos-addons.transcription-controller", qos: .utility)

    /// Main-queue state.
    private(set) var runningMode: Mode?
    /// What should run. Reset by every change of power source.
    private(set) var choice: Choice {
        didSet {
            store.set(choice.rawValue, forKey: Self.choiceKey)
            store.set(isOnAC() ? "ac" : "battery", forKey: Self.choicePowerKey)
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
        let onAC = isOnAC()
        var saved: Choice?
        if store.string(forKey: Self.choicePowerKey) == (onAC ? "ac" : "battery") {
            saved = store.string(forKey: Self.choiceKey).flatMap(Choice.init(rawValue:))
        } else if !onAC {
            // The old battery-only keys: a stop or a choice made on battery.
            if store.bool(forKey: Self.legacyKeys[0]) { saved = .off }
            saved = store.string(forKey: Self.legacyKeys[1]).flatMap(Choice.init(rawValue:)) ?? saved
        }
        Self.legacyKeys.forEach(store.removeObject(forKey:))
        // `didSet` does not run in init.
        choice = saved ?? Self.defaultChoice(onAC: onAC)
    }

    /// What should be running for a choice, if anything.
    static func desiredMode(_ choice: Choice) -> Mode? {
        switch choice {
        case .transcribe: return .full
        case .record: return .captureOnly
        case .listen: return .sentinel
        case .off: return nil
        }
    }

    static func state(_ choice: Choice) -> State {
        switch choice {
        case .transcribe: return .transcribing
        case .record: return .recording
        case .listen: return .listening
        case .off: return .stopped
        }
    }

    var desiredMode: Mode? { Self.desiredMode(choice) }

    var state: State { Self.state(choice) }

    /// Call once on launch: applies the current choice and arms the heartbeat.
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

    /// Call from PowerMonitor's AC/battery callbacks: plugging in resets to 🟢,
    /// unplugging to 🟠 listening.
    func powerDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.choice = Self.defaultChoice(onAC: self.isOnAC())
            self.apply()
        }
    }

    /// The menu's rows, on any power source.
    func setChoice(_ choice: Choice) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 🟠 picked while already recording: it is recording, which is more than
            // listening — going back to listening would only drop the disk.
            if choice == .listen, self.choice == .record { return }
            if choice == .record, self.choice == .listen, self.runningMode == .sentinel,
               self.isWhisperRunning(), self.wakeSentinel?() == true {
                // Its SENTINEL_WAKE:menu arrives next and is ignored, the
                // choice being `record` already.
                self.choice = .record
                self.runningMode = .captureOnly
                self.apply()
                return
            }
            self.choice = choice
            self.apply()
        }
    }

    /// 👂 Whisper's `SENTINEL_WAKE:<why>`: the listening process has already
    /// written its ring out and is recording — so the state moves to
    /// `recording` **without** a restart (a restart would lose the
    /// ring). Ignored unless we are listening. Main queue.
    func sentinelWoke(_ why: String) {
        guard choice == .listen else { return }
        choice = .record
        if runningMode == .sentinel { runningMode = .captureOnly }
        onSentinelWake?(why)
        apply()
    }

    /// Re-launch Whisper so it picks up changed launch settings — in the mode
    /// the choice asks for, or not at all.
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

    /// Sync Whisper to the current choice. Main queue.
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
