import Cocoa

/// 〰️🔴🔋 — the microphones are being written to disk while on battery.
///
/// On battery whisper only records (`TranscriptionController.Mode.captureOnly`);
/// the text arrives when the charger does. A microphone that records without
/// transcribing is a state worth seeing, so while it lasts the app's own
/// bottom-left pill says so (Victor, 2026-11-03).
///
/// **What it shows** (2026-11-05, Victor: *"waveform (luată din badge walkie
/// talkie, dar ne-animat/strălucit), un 🔴 care clipește lent, apoi emoji baterie
/// ca acum"*; it said `👂/🔋` until then): the sound, the red light of a take in
/// progress, why there is no text. The gaps either side of the 🔴 match by eye,
/// between the inks (*"distanța … egală"*). The menu-bar icon carries a red zig-zag (`MicOverlay`).
///
/// **Two buttons** (Victor, 2026-11-03: *"să aibă 2 butoane: snooze 1h ⏱️ +
/// Stop ❌"*; label `Stop ❌`), and only the buttons act — a click elsewhere on the pill does
/// nothing, so a stray one costs no meeting:
/// - `Snooze 1h ⏱️` (top; also a right-click) hides it for an hour, not for
///   good: an hour later, still on battery and still recording, it comes back.
///   The snooze lasts until the charger is plugged in — the next unplugging
///   shows it again at once.
/// - `Stop ❌` stops the *disk*, not the ears (2026-11-24): whisper keeps
///   listening and records again by itself on voice (`.listen`, `onStop`). It
///   used to stop everything until AC, and a press at 12:40 that day cost the
///   whole 12:30–13:30 meeting. Stopping everything is the menu's alone.
///
/// **When the listener records again** a second, quiet pill says so — grey,
/// one `Dismiss`, nothing else (Victor: *"reiei automat și ridici un overlay.
/// Doar dismiss pe el … ceva subtil"*) — and the orange one is snoozed for the
/// hour, so no Stop ❌ comes back with it.
final class BatteryRecordingNotice {
    static let text = "🔋"
    /// 🔋 stands narrow in a wide emoji cell: this much empty cell, plus the
    /// label's own inset, comes before its ink at the banner's 38 pt. Measured
    /// off the screen; it is what makes the 🔴's two gaps equal.
    static let batteryLeadTrim: CGFloat = 11.5
    static let snooze: TimeInterval = 3600
    static let color = NSColor.systemOrange.withAlphaComponent(0.85)

    private let screensProvider: () -> [NSScreen]
    private let now: () -> Date
    private var banner: BottomLeftBanner?
    /// The quiet "recording again" pill, up until dismissed or the charger.
    private var resumedBanner: BottomLeftBanner?
    static let resumedColor = NSColor(white: 0.18, alpha: 0.72)
    private var snoozeTimer: Timer?
    private(set) var snoozedUntil: Date?
    private(set) var recording = false
    /// The `Stop ❌` button: switch the battery recording off (until AC).
    var onStop: (() -> Void)?

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.pillScreens },
         now: @escaping () -> Date = Date.init) {
        self.screensProvider = screensProvider
        self.now = now
    }

    var isVisible: Bool { banner?.isVisible ?? false }
    var isResumedVisible: Bool { resumedBanner?.isVisible ?? false }

    /// What the quiet pill says, by `SENTINEL_WAKE` reason.
    static func resumedText(_ why: String) -> String {
        if why == "call" { return "🔴 Call started — recording again" }
        if why == "menu" { return "🔴 Recording again" }
        return "🔴 Heard voices — recording again"
    }

    /// 👂 The listener is recording again: snooze the orange pill for the hour
    /// and raise the quiet one. Main thread, before the state change.
    func resumedOnVoice(_ why: String) {
        overlayInfo("👂 battery recording resumed on its own (\(why))")
        snoozeNow()
        // The menu's "Record now" is his own click: nothing to announce.
        guard why != "menu" else { return }
        resumedBanner?.dismiss(animated: false)
        let b = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
        b.clickOnly = true
        b.onHover = { [weak self] in self?.dismissResumed() }
        b.onHoverCountdownExpired = { [weak self] in self?.dismissResumed() }
        b.show(text: Self.resumedText(why), backgroundColor: Self.resumedColor,
               font: NSFont.systemFont(ofSize: 20), clickAction: .dismiss)
        resumedBanner = b
    }

    func dismissResumed() {
        resumedBanner?.dismissSinking()
        resumedBanner = nil
    }

    /// Whether the pill should be up — the policy, without any AppKit.
    static func shouldShow(recording: Bool, snoozedUntil: Date?, now: Date) -> Bool {
        guard recording else { return false }
        guard let until = snoozedUntil else { return true }
        return now >= until
    }

    /// Main thread. Call on every `TranscriptionController.State` change.
    func update(_ state: TranscriptionController.State) {
        recording = state == .recordingOnBattery
        if state == .onAC { dismissResumed() }
        if state == .onAC {
            // The charger ends the snooze: the next battery stretch shows at once.
            snoozedUntil = nil
            snoozeTimer?.invalidate()
            snoozeTimer = nil
        }
        refresh()
    }

    /// The pill was clicked (or right-clicked).
    func snoozeNow() {
        snoozedUntil = now().addingTimeInterval(Self.snooze)
        overlayInfo("👂/🔋 snoozed until \(MicDeadAlarm.hhmm(snoozedUntil!))")
        snoozeTimer?.invalidate()
        let t = Timer(timeInterval: Self.snooze, repeats: false) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        snoozeTimer = t
        refresh()
    }

    /// The `Stop ❌` button: off the disk, still listening (`.listen`). The
    /// state change that follows takes the pill down.
    func stopNow() {
        overlayInfo("👂/🔋 battery recording stopped — listening, records again on voice")
        onStop?()
    }

    private func refresh() {
        let show = Self.shouldShow(recording: recording, snoozedUntil: snoozedUntil, now: now())
        if show, banner == nil {
            let b = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
            b.clickOnly = true
            b.icon = Self.waveform(height: 28, colour: .white)
            b.blinkingMark = Self.recordingDot(size: 28)
            b.textLeadTrim = Self.batteryLeadTrim
            // Top button (and right-click) = snooze; bottom button = stop.
            b.onHoverCountdownExpired = { [weak self] in self?.snoozeNow() }
            b.onHover = { [weak self] in self?.stopNow() }
            b.show(text: Self.text, backgroundColor: Self.color,
                   autoAction: .snoozeHour, clickAction: .stopUntilAC)
            banner = b
        } else if !show, let b = banner {
            b.dismissSinking()
            banner = nil
        }
    }

    /// The sound wave Walkie Talkie's launch tab draws between the microphone and
    /// the engine (`WaveGlyph`), same corners, proportions and wire, without the
    /// light that travels along it. Copied because that app must not depend on
    /// this one. −1…1 about the flat line, up positive.
    private static let waveCorners: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.086, y: 0), CGPoint(x: 0.136, y: 0.248),
        CGPoint(x: 0.164, y: -0.24), CGPoint(x: 0.240, y: 0.56), CGPoint(x: 0.286, y: -0.62),
        CGPoint(x: 0.371, y: 1.0), CGPoint(x: 0.460, y: -0.992), CGPoint(x: 0.546, y: 0.44),
        CGPoint(x: 0.621, y: -0.488), CGPoint(x: 0.707, y: 0.82), CGPoint(x: 0.800, y: -0.808),
        CGPoint(x: 0.857, y: 0.328), CGPoint(x: 0.893, y: 0), CGPoint(x: 1, y: 0),
    ]
    static let waveAspect: CGFloat = 1.4

    static func waveform(height h: CGFloat, colour: NSColor) -> NSImage {
        let w = (h * waveAspect).rounded()
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let wire = max(1.5, (h * 0.085).rounded())
            let half = (h - wire) / 2
            ctx.setStrokeColor(colour.cgColor)
            ctx.setLineWidth(wire)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addLines(between: waveCorners.map {
                CGPoint(x: wire / 2 + $0.x * (w - wire), y: h / 2 + $0.y * half)
            })
            ctx.strokePath()
            return true
        }
    }

    /// 🔴 as a picture: `BottomLeftBanner.blinkingMark` blinks a view, and a
    /// character in the label could only blink with the 🔋 beside it.
    static func recordingDot(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.9)]
            let dot = "🔴" as NSString
            let box = dot.size(withAttributes: attrs)
            dot.draw(at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2),
                     withAttributes: attrs)
            return true
        }
    }

    func stateJSON() -> String {
        let until = snoozedUntil.map { String(Int($0.timeIntervalSince1970)) } ?? "null"
        return "{\"recording\":\(recording),\"visible\":\(isVisible),\"resumed_visible\":\(isResumedVisible),\"snoozed_until\":\(until)}"
    }
}
