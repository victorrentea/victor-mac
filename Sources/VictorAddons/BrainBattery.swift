import AppKit
import Foundation

/// 🧠 How much attention the room has left, as a pure function of the clock.
///
/// An audience lasts about an hour and a quarter between breaks (the same rhythm
/// that turns ⏱️ Resumed yellow), so the battery is full when a break ends and
/// drains linearly to empty over `span`. Past empty it stays at zero and counts
/// how long the room has been running on nothing — that is when it blinks red.
enum BrainEnergy {
    static let defaultSpan: TimeInterval = 75 * 60
    /// After lunch the room fades faster — an hour, not an hour and a quarter
    /// (Victor, 2026-11-17: *"după pauza de masă la doar o oră, că mereu eu mor"*).
    static let afterLunchSpan: TimeInterval = 60 * 60
    /// A break that really lasted this long was lunch: the 🍽️ rows of the break
    /// menu start at 30 min, every ☕ row stops at 15.
    static let lunchMinLength: TimeInterval = 30 * 60

    static func isLunch(breakStartedAt: Date?, endedAt: Date) -> Bool {
        guard let breakStartedAt else { return false }
        return endedAt.timeIntervalSince(breakStartedAt) >= lunchMinLength
    }

    /// How long the battery lasts from `reference`: an hour when it was filled
    /// by the end of lunch, 75 min otherwise — a **Refill now** after lunch
    /// counts as a normal refill.
    static func span(reference: Date?, lunchEndedAt: Date?) -> TimeInterval {
        guard let reference, let lunchEndedAt,
              abs(reference.timeIntervalSince(lunchEndedAt)) < 1 else { return defaultSpan }
        return afterLunchSpan
    }
    /// Three hours after the last break the battery is no longer telling anyone
    /// anything — the day is over, or lunch ran long — so it goes idle, which
    /// **hides** the item, until the next break ends (Victor, 2026-11-12).
    static let staleAfter: TimeInterval = 3 * 3600

    enum State: Equatable {
        /// No break in the last 3 h and no refill: the item is hidden.
        case idle
        /// `level` in 0...1, `remaining` seconds until empty.
        case draining(level: Double, remaining: TimeInterval)
        /// Empty for `overdue` seconds.
        case depleted(overdue: TimeInterval)
    }

    /// The moment the battery was last full: the later of the end of the last
    /// break and a refill. One older than `staleAfter` counts as none, and so
    /// does one in the future (clock change) — except a refill at most
    /// `scheduledAhead` away, which is a session's scheduled start
    /// (`sessionStart`): until then the battery waits full.
    static func reference(breakEndedAt: Date?, refilledAt: Date?, now: Date) -> Date? {
        func recent(_ d: Date, ahead: TimeInterval) -> Bool {
            let age = now.timeIntervalSince(d)
            return age >= -ahead && age <= staleAfter
        }
        return [breakEndedAt.flatMap { recent($0, ahead: 0) ? $0 : nil },
                refilledAt.flatMap { recent($0, ahead: scheduledAhead) ? $0 : nil }]
            .compactMap { $0 }.max()
    }

    /// How far ahead a scheduled refill may sit: the longest wait `sessionStart` gives.
    static let scheduledAhead: TimeInterval = 30 * 60

    /// When a session started at `startedAt` really starts draining the room: the
    /// next xx:00 or xx:30 on the local clock — or `startedAt` itself if it is
    /// exactly one. The trainer presses Start a few minutes early, while people
    /// are still walking in (Victor, 2026-11-18).
    static func sessionStart(startedAt: Date, calendar: Calendar = .current) -> Date {
        let c = calendar.dateComponents([.minute, .second, .nanosecond], from: startedAt)
        let into = TimeInterval((c.minute ?? 0) % 30 * 60 + (c.second ?? 0)) + Double(c.nanosecond ?? 0) / 1e9
        return into < 0.001 ? startedAt : startedAt + (30 * 60 - into)
    }

    /// Whether the item is on the menu bar: not when idle, and not after **Hide**
    /// until something refills it again — the next break's end or a refill
    /// (Victor, 2026-11-12: *"besides Refill now, another option to hide"*).
    static func isShown(_ state: State, reference: Date?, hiddenAt: Date?) -> Bool {
        if state == .idle { return false }
        guard let hiddenAt, let reference else { return true }
        return reference > hiddenAt
    }

    static func state(reference: Date?, now: Date, span: TimeInterval = defaultSpan) -> State {
        guard let reference, span > 0 else { return .idle }
        let elapsed = max(0, now.timeIntervalSince(reference))
        if elapsed >= span { return .depleted(overdue: elapsed - span) }
        let remaining = span - elapsed
        return .draining(level: remaining / span, remaining: remaining)
    }

    /// The fill's colour, the way a phone reads its own battery (Victor,
    /// 2026-11-13): green down to half, yellow down to 15%, then red — and at 5%
    /// or less, empty included, the red blinks.
    enum Charge: Equatable { case green, yellow, red, blinkingRed }

    static func charge(_ state: State) -> Charge {
        switch state {
        case .idle: return .green
        case .depleted: return .blinkingRed
        case let .draining(level, _):
            if level >= 0.5 { return .green }
            if level > 0.15 { return .yellow }
            return level > 0.05 ? .red : .blinkingRed
        }
    }

    /// The minutes are a guess about a room, not a measurement — hence "about"
    /// (Victor, 2026-11-12: *"înainte de timpul rămas spune aproximativ"*).
    static func describe(_ state: State) -> String {
        switch state {
        case .idle:
            return "no break yet today"
        case let .draining(level, remaining):
            // 🔋 while there is charge to spend, 🪫 once it is in the red (Victor, 2026-11-23).
            let icon = level > 0.15 ? "🔋" : "🪫"   // the red zone of `charge`
            return "\(icon) left: ~\(spoken(remaining)) (\(Int((level * 100).rounded()))%)"
        case let .depleted(overdue):
            return "☢️ depleted: \(ago(overdue))"
        }
    }

    /// The three lines of the tooltip and the grey menu rows: the title, how much
    /// is left (or how long it has been empty), and when the battery was last full.
    static func lines(_ state: State, reference: Date?, now: Date) -> [String] {
        let started: String
        if let reference, reference > now {
            started = "🕒 starts in ~\(spoken(reference.timeIntervalSince(now)))"
        } else if let reference {
            started = "🕒 started: \(ago(max(0, now.timeIntervalSince(reference))))"
        } else {
            started = "🕒 started: —"
        }
        return ["🧠 Brain Stamina", describe(state), started]
    }

    /// "40 min ago", "1h 5m ago", "just now" — for how long ago something was.
    static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        let m = Int(seconds / 60)
        return m < 60 ? "\(m) min ago" : minutes(seconds) + " ago"
    }

    /// "~10 minutes" / "1 minute" — a spoken length, rounded up: "about" is implied.
    static func spoken(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded(.up))
        if m >= 60 { return minutes(seconds) }
        return "\(m) minute\(m == 1 ? "" : "s")"
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded(.up))
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
}

enum BrainBatterySettings {
    static let enabledKey = "BrainBattery.enabled"
    static let refilledAtKey = "BrainBattery.refilledAt"
    static let hiddenAtKey = "BrainBattery.hiddenAt"
    static let lunchEndedAtKey = "BrainBattery.lunchEndedAt"

    /// The end of the last break if it was lunch, else nil (`BrainEnergy.span`).
    static var lunchEndedAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: lunchEndedAtKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: lunchEndedAtKey) }
    }

    /// 👩🏻‍💻 Extras › 🧠 Show Brain Battery — on by default.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// When **Hide** was clicked; the item stays off until a later refill.
    static var hiddenAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: hiddenAtKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: hiddenAtKey) }
    }

    static var refilledAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: refilledAtKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: refilledAtKey) }
    }
}

/// The picture: drawn to read as **the macOS battery** sitting next to it — a
/// thin translucent rounded outline, a faint nub, a rounded fill inset from it —
/// with the fill in the system battery's own colours (`BrainEnergy.charge`:
/// green, yellow, red) — just the battery, no brain drawn (Victor, 2026-11-17).
/// The outline never changes colour, like
/// the system's; at 5% or less only a thin red sliver at the left blinks — the
/// way macOS shows a battery about to die (`blinkOn`, toggled by the caller).
enum BrainBatteryIcon {
    static let green = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    static let yellow = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)
    static let alarmRed = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
    static let size = NSSize(width: 28, height: 16)

    static func fillColor(_ charge: BrainEnergy.Charge) -> NSColor {
        switch charge {
        case .green: return green
        case .yellow: return yellow
        case .red, .blinkingRed: return alarmRed
        }
    }

    static func image(for state: BrainEnergy.State, blinkOn: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state: state, blinkOn: blinkOn)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Brain battery: " + BrainEnergy.describe(state)
        return image
    }

    static func draw(state: BrainEnergy.State, blinkOn: Bool) {
        // Measured off the system battery on the 2× menu bar (2026-11-12): a
        // 23×12 pt body, a 1 pt outline of white (black in light mode) at 45%,
        // a 1 pt gap, then the fill — inset 2 pt, so 8 pt tall.
        let body = NSRect(x: 1, y: 2, width: 23, height: 12)
        let nub = NSRect(x: body.maxX + 1, y: body.midY - 2, width: 1.5, height: 4)
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        let inner = body.insetBy(dx: 2, dy: 2)

        var level = 0.0
        if case let .draining(l, _) = state { level = l }
        let charge = BrainEnergy.charge(state)

        let frame = NSColor.labelColor.withAlphaComponent(0.45)
        frame.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        frame.setFill()
        NSBezierPath(roundedRect: nub, xRadius: 0.75, yRadius: 0.75).fill()

        // Never thinner than the sliver, so the last red minutes stay visible;
        // blinking, the sliver is the whole fill and goes fully dark between beats.
        let sliver: CGFloat = 2.5
        var fillWidth: CGFloat = state == .idle ? 0 : max(sliver, inner.width * level)
        if charge == .blinkingRed { fillWidth = blinkOn ? sliver : 0 }
        if fillWidth > 0 {
            fillColor(charge).setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillWidth, height: inner.height),
                         xRadius: 1.75, yRadius: 1.75).fill()
        }
    }
}

/// 🧠 **Brain battery** (2026-11-12) — its own menu bar item beside 💬, so the
/// room's remaining attention is read at a glance, never behind a click.
///
/// Refills by itself when a ☕ break ends (`breakEndedAt`, the same instant
/// ⏱️ Resumed counts from) and when the trainer starts a training-assistant
/// session (`handleSessionStarted`) — draining only from the next xx:00 or
/// xx:30, full until then; **Refill now** in its menu covers a break
/// taken without the timer. Shown while 👩🏻‍💻 Extras ›
/// 🧠 Show Brain Battery is ticked (default on) — and even then only from the
/// end of a break until 3 h after it (`BrainEnergy.staleAfter`); the next
/// break's end brings it back.
final class BrainBatteryIndicator: NSObject, NSMenuDelegate {
    private let breakEndedAt: () -> Date?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let statusRows = (0..<3).map { _ in NSMenuItem(title: "", action: nil, keyEquivalent: "") }
    /// ☕️ Break, whose submenu is the 💬 menu's (`MenuBarManager.lendBreakSubmenu`).
    private let breakRow = NSMenuItem(title: "☕️ Break", action: nil, keyEquivalent: "")
    /// Set by `AppDelegate`: hands `breakRow` the one ☕️ Break submenu.
    var lendBreakSubmenu: ((NSMenuItem) -> Void)?
    private var summary: [String] = []
    private var tick: Timer?
    private var blinkTimer: Timer?
    private var blinkOn = true
    private(set) var state: BrainEnergy.State = .idle
    /// The Extras tick (🧠 Show Brain Battery).
    private var enabled = false
    /// ☕ `UntilBreakCountdown` borrows this slot while it counts: the time to
    /// the break sits exactly where the battery was, and the battery comes back
    /// at zero. Shown even with the battery ticked off.
    private var countdownTitle: NSAttributedString?
    private var countdownMenu: NSMenu?
    /// ☕ A break is on: the slot shows a coffee instead of the battery that is
    /// about to refill (2026-11-24, Victor: *"în timpul pauzei, în locul bateriei
    /// depleted, o să apară o cafea"*). Just the cup, no time: `☕ 9:42` is the
    /// countdown TO the break, and the two must not be confused.
    private var breakActive = false
    /// ☕ The big hover card while the countdown owns the slot; 🧠 the 1.5× tooltip otherwise.
    private lazy var hoverTip = UntilBreakHoverTip(button: { [weak self] in self?.statusItem?.button })

    init(breakEndedAt: @escaping () -> Date?) {
        self.breakEndedAt = breakEndedAt
        super.init()
        for row in statusRows {
            row.isEnabled = false          // grey: information, not an action
            menu.addItem(row)
        }
        menu.addItem(.separator())
        // ☕️ Break — the 💬 menu's own submenu, lent on open (`lendBreakSubmenu`), so a
        // depleted room is one click from its break (2026-11-25).
        breakRow.isEnabled = true
        menu.addItem(breakRow)
        menu.addItem(.separator())
        let refill = NSMenuItem(title: "Refill now", action: #selector(refillNow), keyEquivalent: "")
        refill.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refill")
        refill.target = self
        menu.addItem(refill)
        let hide = NSMenuItem(title: "Hide until the next break", action: #selector(hideNow), keyEquivalent: "")
        hide.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hide")
        hide.target = self
        menu.addItem(hide)
        menu.delegate = self
    }

    /// Shows or hides the item; called at launch and from the Extras tick.
    func setVisible(_ visible: Bool) {
        enabled = visible
        syncItem()
    }

    /// ☕ Lend the slot to the countdown (`title` non-nil) or take it back (nil).
    func showCountdown(_ title: NSAttributedString?, menu: NSMenu) {
        let modeChanged = (title == nil) != (countdownTitle == nil)
        countdownTitle = title
        countdownMenu = menu
        if title == nil { hoverTip.update(remaining: nil) }   // the item may go away before a draw()
        if modeChanged { syncItem() } else { draw() }
    }

    /// From `BreakTimeMirror`'s tick: a real break started or ended.
    func setBreakActive(_ active: Bool) {
        guard active != breakActive else { return }
        breakActive = active
        refresh()
    }

    /// `GET /test/break/until/tip`: the hover card for 4 s with nobody's hand on
    /// the mouse, under the slot's own window (the main display, not the projector).
    func showCountdownTipForTest() -> Bool {
        // Whichever card the slot has: ☕ countdown, else the 🧠 1.5× tooltip.
        return hoverTip.pin(seconds: 4)
    }

    /// Where the slot is on screen (global coordinates), for the ☕ −1 to fly at.
    ///
    /// On the **retina's** menu bar, not wherever the item's window lives: the
    /// window sits on one display's menu bar (whichever macOS picked), every
    /// other menu bar draws a copy, and the −1's canvas — like the room's
    /// projector — is the retina only, so a slot homed on the ASUS would have
    /// the −1 fly off its own panel.
    var slotCenterGlobal: CGPoint? {
        guard let item = statusItem, item.isVisible, let w = item.button?.window else { return nil }
        let r = MenuBarSlot.rect(of: w.frame, on: AppDelegate.findRetinaScreen())
        return CGPoint(x: r.midX, y: r.midY)
    }

    private func syncItem() {
        let visible = enabled || countdownTitle != nil
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            statusItem = item
            tick = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
            refresh()
        } else if !visible, let item = statusItem {
            tick?.invalidate(); tick = nil
            blinkTimer?.invalidate(); blinkTimer = nil
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    /// Before the menu is drawn: borrow the ☕️ Break submenu for `breakRow`.
    func menuNeedsUpdate(_ menu: NSMenu) { lendBreakSubmenu?(breakRow) }

    /// Re-reads the clock; also called the moment a break ends, so the refill
    /// shows at once instead of on the next 10 s tick.
    func refresh() {
        guard statusItem != nil else { return }
        let now = Date()
        let reference = BrainEnergy.reference(breakEndedAt: breakEndedAt(),
                                              refilledAt: BrainBatterySettings.refilledAt, now: now)
        state = BrainEnergy.state(reference: reference, now: now,
                                  span: BrainEnergy.span(reference: reference,
                                                         lunchEndedAt: BrainBatterySettings.lunchEndedAt))
        if BrainEnergy.charge(state) == .blinkingRed {
            if blinkTimer == nil {
                blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.draw()
                }
            }
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkOn = true
        }
        summary = BrainEnergy.lines(state, reference: reference, now: now)
        for (row, line) in zip(statusRows, summary) { row.title = line }
        statusItem?.isVisible = countdownTitle != nil
            || (enabled && breakActive)
            || (enabled && BrainEnergy.isShown(state, reference: reference,
                                               hiddenAt: BrainBatterySettings.hiddenAt))
        draw()
    }

    private func draw() {
        guard let item = statusItem else { return }
        if let countdownTitle {
            item.button?.image = nil
            item.button?.attributedTitle = countdownTitle
            // The big card (`UntilBreakHoverTip`) replaces the native tooltip:
            // both at once would stack a small grey one over it.
            item.button?.toolTip = nil
            item.menu = countdownMenu
            hoverTip.update(remaining: countdownTitle.string.replacingOccurrences(of: "☕ ", with: ""))
            return
        }
        item.menu = menu
        if breakActive {
            item.button?.image = nil
            item.button?.title = "☕"
            item.button?.toolTip = nil
            hoverTip.update(lines: ["Break — the battery refills when it ends"])
            return
        }
        item.button?.title = ""
        item.button?.image = BrainBatteryIcon.image(for: state, blinkOn: blinkOn)
        // 🧠 Our own 1.5× card instead of the small native tooltip.
        item.button?.toolTip = nil
        hoverTip.update(lines: summary)
    }

    /// Full again, as of now: **Refill now**.
    @objc func refillNow() {
        BrainBatterySettings.refilledAt = Date()
        refresh()
    }

    /// A training session was just started: full, and starting to drain at the
    /// next xx:00 or xx:30 (`BrainEnergy.sessionStart`); full until then.
    func refillForSessionStart() {
        BrainBatterySettings.refilledAt = BrainEnergy.sessionStart(startedAt: Date())
        refresh()
    }

    /// Off the menu bar until the next break ends; the Extras tick stays on.
    @objc private func hideNow() {
        BrainBatterySettings.hiddenAt = Date()
        refresh()
    }
}
