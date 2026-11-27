import Cocoa

/// 🎤 The DJI transmitter is gone: a red pill in the bottom-left corner of
/// every screen that **stays until Victor clicks it**.
///
/// 2026-09-26: the clip-on transmitter's battery ran out after ~5 h of teaching
/// and he went on talking into a receiver that delivered nothing but zeros.
/// Two sources raise it: the receiver's own "no transmitter linked"
/// (`DjiReceiverMonitor`, the real signal) and, when that USB status cannot be
/// read, whisper's exact-digital-silence guess (`dead_input.py`).
///
/// **The app's own notification**, `BottomLeftBanner` — the same corner pill
/// as every other message here (Victor: *"notificarea trebuie dată din macOS
/// Addons în stilul ei, overlay stânga jos"*), tinted red like the roaming
/// warning. **Click-only** (`clickOnly`): unlike the roaming pill, a hover does
/// not dismiss it — only a deliberate click (left or right) — **or the
/// transmitter coming back** (2026-10-06, Victor: *"stays there even if I
/// reconnect another DJI Mini or the same one. It should auto hide."*; until
/// then it stayed up after the link was back, so the minutes missing would be
/// noticed). Any transmitter counts: the receiver's link byte, not one TX.
/// Re-arming is the sources' job: each reports a dead run once, and again only
/// after the audio / link came back and went again.
final class MicDeadAlarm {
    static let color = NSColor.systemRed.withAlphaComponent(0.85)
    /// Smaller than the corner pill's 54 pt: the message is a sentence, and the
    /// pill caps at half the screen — at 54 pt it would be cut on the retina.
    static let fontSize: CGFloat = 24   // 34 before the pill shrank to 70 % (2026-11-03)

    private let screensProvider: () -> [NSScreen]
    /// The Basso that goes with it — injectable so the tests stay silent.
    private let sound: () -> Void
    private var banner: BottomLeftBanner?
    private(set) var silentSince: Date?
    private var shownText: String?

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.pillScreens },
         sound: @escaping () -> Void = { NSSound(named: NSSound.Name("Basso"))?.play() }) {
        self.screensProvider = screensProvider
        self.sound = sound
    }

    var isRaised: Bool { silentSince != nil }

    static func hhmm(_ d: Date) -> String {
        let f = DateFormatter()
        // POSIX, or the user's 12-hour override turns HH into "3:10 PM".
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// Whisper's guess: the receiver is streaming exact zeros.
    static func text(since: Date) -> String {
        "🎤 DJI TX silent since \(hhmm(since)) — battery dead?"
    }

    /// The receiver's own word: no transmitter linked (`DjiReceiverMonitor`).
    /// Worded from the last battery level seen before the link went: at 6–7
    /// (DJI's own low warning and the shutdown step) it is almost certainly
    /// the battery; higher, it was switched off or walked out of range.
    static func linkLostText(since: Date, lastLevel: Int?) -> String {
        let why = (lastLevel ?? 0) >= 6 ? "battery dead?" : "off or out of range?"
        return "🎤 DJI TX gone since \(hhmm(since)) — \(why)"
    }

    /// Raise the alarm, or leave it alone if it is already up: the moment the
    /// FIRST run began is the one worth reading, and a repeat report of the
    /// same death must not move it.
    ///
    /// `screens` overrides where it is drawn — only the test hooks use it, to
    /// keep a test off the projected retina.
    func raise(since: Date, text custom: String? = nil, screens: (() -> [NSScreen])? = nil) {
        guard silentSince == nil else {
            overlayInfo("🎤 DJI reported dead again — the alarm is already up")
            return
        }
        silentSince = since
        let text = custom ?? Self.text(since: since)
        shownText = text
        overlayError("🎤❌ alarm raised: \(text)")
        let b = BottomLeftBanner(screensProvider: screens ?? screensProvider, hoverable: true)
        banner = b
        b.clickOnly = true
        b.onHover = { [weak self] in self?.acknowledge(by: "click") }
        // Right-click is the pill's "other exit"; for an alarm both mean "seen".
        b.onHoverCountdownExpired = { [weak self] in self?.acknowledge(by: "right-click") }
        b.show(text: text,
               backgroundColor: Self.color,
               font: NSFont.boldSystemFont(ofSize: Self.fontSize),
               clickAction: .dismiss)
        sound()
    }

    /// Victor has seen it, or the transmitter is back (`audioResumed`).
    func acknowledge(by how: String) {
        guard let since = silentSince else { return }
        overlayInfo("🎤 alarm dismissed (\(how)); it said: \(shownText ?? Self.text(since: since))")
        silentSince = nil
        banner?.dismissSinking()
        // The sinking exit runs on its own timer over panels it already holds.
        banner = nil
    }

    /// Audio / link is back: the pill leaves by itself (see the type doc).
    func audioResumed() {
        overlayInfo("🎤 DJI is back" + (isRaised ? " — taking the alarm down" : ""))
        acknowledge(by: "DJI back")
    }

    func stateJSON() -> String {
        let since = silentSince.map { String(Int($0.timeIntervalSince1970)) } ?? "null"
        let visible = banner?.isVisible ?? false
        return "{\"raised\":\(isRaised),\"silent_since\":\(since),\"visible\":\(visible)}"
    }
}

/// 🎤 The DJI transmitter's battery, when it is low: a **red pill in the
/// bottom-left corner that stays until clicked**, `🎤 20%`, **with a sound**,
/// each time the reading changes while it is under 30 % — on the receiver's
/// 7-step gauge levels 5, 6 and 7 (20 %, 10 %, 5 %) — and every minute while
/// it sits on the last step (`DjiReceiverPolicy.lastStepRepeat`). A new step
/// replaces the pill that is up; the TX charging (or reading 30 %+ again)
/// takes it down.
///
/// History: silent 5–8 s glass notices until 2026-11-23 (the TX died with
/// both unseen), then 8 s with a sound — and on 2026-11-27 the 20 % one went
/// by unseen again at 16:01 (Victor: *"I want a warning every time it goes
/// below 20 … red in the corner left overlay"*). So it is the same click-only
/// red pill as `MicDeadAlarm` now, not a transient `StatusBanner` message.
///
/// **The icon alone names the mic** (2026-10-02, Victor: *"nu mai scrie «DJI»
/// … doar icon-ul lui … plus bateria"*): 🎤 is the DJI's glyph in `MicRoster`,
/// and a percentage next to it can only be a battery.
final class DjiBatteryNotice {
    static let color = MicDeadAlarm.color
    /// Low (20 %, 10 %) and last step (5 %): two sounds, so the last one is
    /// told apart without looking.
    static func soundName(level: Int) -> String { level >= 7 ? "Basso" : "Submarine" }

    private let screensProvider: () -> [NSScreen]
    private let sound: (Int) -> Void
    private var banner: BottomLeftBanner?
    private(set) var shownText: String?

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.pillScreens },
         sound: @escaping (Int) -> Void = { level in
             NSSound(named: NSSound.Name(DjiBatteryNotice.soundName(level: level)))?.play() }) {
        self.screensProvider = screensProvider
        self.sound = sound
    }

    var isShown: Bool { shownText != nil }

    static func text(percent: Int) -> String { "🎤 \(percent)%" }

    /// Show (or replace) the red pill. `screens` overrides where it is drawn —
    /// only the test hooks use it, to keep a test off the projected retina.
    func show(level: Int, percent: Int, screens: (() -> [NSScreen])? = nil) {
        let text = Self.text(percent: percent)
        overlayError("🎤🔋 battery notice: \(text) (raw level \(level)/7)")
        banner?.dismissSinking()
        shownText = text
        let b = BottomLeftBanner(screensProvider: screens ?? screensProvider, hoverable: true)
        banner = b
        b.clickOnly = true
        b.onHover = { [weak self, weak b] in self?.hide(by: "click", only: b) }
        b.onHoverCountdownExpired = { [weak self, weak b] in self?.hide(by: "right-click", only: b) }
        b.show(text: text, backgroundColor: Self.color, clickAction: .dismiss)
        sound(level)
    }

    /// Seen, or no longer true (charging, back over 30 %). `only` ignores a
    /// late click on a pill that a newer step has already replaced.
    func hide(by how: String, only which: BottomLeftBanner? = nil) {
        guard let text = shownText else { return }
        if let which, which !== banner { return }
        overlayInfo("🎤🔋 battery notice dismissed (\(how)); it said: \(text)")
        shownText = nil
        banner?.dismissSinking()
        banner = nil
    }
}

/// 🎤 **The receiver is plugged in and no transmitter is on** (2026-11-12,
/// Victor: *"There should be some warning, right? When just the receiver is
/// connected with no transmitter"*). Since the same day the DJI is not used as
/// the microphone in that state (`DjiSourceGate`), so the transcription is
/// quietly on the next mic down the ladder — worth a look before he starts
/// talking with the lavalier on his collar and the TX still off.
///
/// **Only for a TX that was never there**, i.e. the gate going to `no-tx`
/// from anything but `linked`: the receiver appearing (or the app starting)
/// with nothing linked. A linked TX that goes away is `MicDeadAlarm`'s red
/// case, which already fires at the same 5 s; showing both would say one
/// thing twice, and a TX put back in its case on purpose deserves neither.
///
/// Orange, not red — nothing is lost yet, it is a reminder. Click-only like
/// the red one, and it leaves by itself the moment the gate says anything else
/// (a TX linked, the receiver unplugged).
final class DjiNoTxWarning {
    static let color = NSColor.systemOrange.withAlphaComponent(0.9)
    static let text = "🎤 DJI receiver on, no TX — not used as the mic"

    private let screensProvider: () -> [NSScreen]
    private let sound: () -> Void
    private var banner: BottomLeftBanner?
    private var previous: DjiSourceGate.State?
    private(set) var isShown = false

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.pillScreens },
         sound: @escaping () -> Void = { NSSound(named: NSSound.Name("Funk"))?.play() }) {
        self.screensProvider = screensProvider
        self.sound = sound
    }

    static func shouldWarn(from previous: DjiSourceGate.State?, to state: DjiSourceGate.State) -> Bool {
        state == .noTx && previous != .linked && previous != .noTx
    }

    /// Feed every gate change (`DjiReceiverMonitor.onSourceGate`).
    func gateChanged(_ state: DjiSourceGate.State, screens: (() -> [NSScreen])? = nil) {
        defer { previous = state }
        if state != .noTx { hide(by: "gate \(state.rawValue)"); return }
        guard Self.shouldWarn(from: previous, to: state), !isShown else { return }
        show(screens: screens)
    }

    func show(screens: (() -> [NSScreen])? = nil) {
        guard !isShown else { return }
        isShown = true
        overlayError("🎤⚠️ \(Self.text)")
        let b = BottomLeftBanner(screensProvider: screens ?? screensProvider, hoverable: true)
        banner = b
        b.clickOnly = true
        b.onHover = { [weak self] in self?.hide(by: "click") }
        b.onHoverCountdownExpired = { [weak self] in self?.hide(by: "right-click") }
        b.show(text: Self.text,
               backgroundColor: Self.color,
               font: NSFont.boldSystemFont(ofSize: MicDeadAlarm.fontSize),
               clickAction: .dismiss)
        sound()
    }

    func hide(by how: String) {
        guard isShown else { return }
        isShown = false
        overlayInfo("🎤 no-TX warning down (\(how))")
        banner?.dismissSinking()
        banner = nil
    }
}

/// 🎤 **The receiver fell off USB while it was the microphone** (2026-11-25,
/// Victor: *"aveam DJI Mic Mini conectat, verde ambele leduri de pe RX, dar
/// microfonul activ era Mac"*). At 17:11 that day the receiver vanished from
/// macOS mid-training — never came back — and the last 15 minutes were
/// transcribed off the MacBook's microphone with no word said: the monitor
/// only logged *"status stream ended (unplugged?)"*. The receiver runs on its
/// own battery, so it stays lit and linked to the TX while the Mac no longer
/// sees it; the LEDs cannot tell him.
///
/// Raises the same red, click-only `MicDeadAlarm` pill as a lost transmitter,
/// but **only for `linked → absent`**: the DJI was the live mic and is now
/// gone from the device list. A receiver unplugged with no TX on (`noTx`) was
/// not being listened to; a status stream that drops and reopens never
/// reaches `absent`. The pill leaves by itself when the gate says `linked`
/// again (replugged, TX on) — or with a click, for an unplug on purpose.
final class DjiUnplugWatch {
    private let raise: (Date) -> Void
    private let resume: () -> Void
    private var previous: DjiSourceGate.State?
    private(set) var isRaised = false

    init(raise: @escaping (Date) -> Void, resume: @escaping () -> Void) {
        self.raise = raise
        self.resume = resume
    }

    static func text(since: Date) -> String {
        "🎤 DJI receiver off USB since \(MicDeadAlarm.hhmm(since)) — replug it"
    }

    static func shouldRaise(from previous: DjiSourceGate.State?, to state: DjiSourceGate.State) -> Bool {
        previous == .linked && state == .absent
    }

    /// Feed every gate change (`DjiReceiverMonitor.onSourceGate`).
    func gateChanged(_ state: DjiSourceGate.State, now: Date = Date()) {
        defer { previous = state }
        if Self.shouldRaise(from: previous, to: state) {
            overlayError("🎤 DJI receiver dropped off USB while it was the mic")
            isRaised = true
            raise(now)
        } else if state == .linked, isRaised {
            isRaised = false
            resume()
        }
    }
}
