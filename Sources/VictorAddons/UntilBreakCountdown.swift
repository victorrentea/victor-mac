import AppKit
import Foundation

/// ☕ **The time until the voted break, in the menu bar** (2026-11-23, Victor:
/// *"timpul până la pauză să fie în locul bateriei de sus … o cafea și un
/// countdown … de la zece minute inițial și minusurile să se ducă acolo … până
/// ajunge la zero și apoi să apară timerul, ca de obicei, de pauză, ca să nu se
/// confunde cele două"*).
///
/// Until then the first ☕ opened a floating "UNTIL BREAK" watch that looked
/// like the break watch itself. Now the floating watch is only ever the break;
/// the countdown to it is `☕ 9:42`, drawn in the 🧠 Brain Battery's own
/// menu-bar slot (`BrainBatteryIndicator.showCountdown`), so it sits exactly
/// where the battery was. Each ☕'s red −1 flies up to it and takes a minute
/// off on landing. At zero the slot goes back to the battery, a gong strikes,
/// and the ☕️ Break menu opens to pick the break's length — the usual watch.
///
/// The deadline is persisted, so a redeploy mid-vote keeps counting.
final class UntilBreakCountdown {
    static let startMinutes = 10
    private static let kDeadline = "UntilBreak.deadline"
    private static let flashSeconds: TimeInterval = 0.7

    /// Draws the slot: the title while counting, nil to give it back to the battery.
    var render: ((NSAttributedString?) -> Void)?
    /// Zero reached by the clock or by the last −1.
    var onExpired: (() -> Void)?

    private var tick: Timer?
    private var flashUntil: Date?
    let menu = NSMenu()

    init() {
        let cancel = NSMenuItem(title: "Cancel the countdown to the break", action: #selector(cancelAction), keyEquivalent: "")
        cancel.target = self
        menu.addItem(cancel)
    }

    private(set) var deadline: Date? {
        get { UserDefaults.standard.object(forKey: Self.kDeadline) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.kDeadline) }
    }

    var isRunning: Bool { tick != nil }

    /// Whole seconds left, rounded up so the slot never reads 0:00 while counting.
    var remaining: Int { Self.remaining(deadline: deadline, now: Date()) }

    static func remaining(deadline: Date?, now: Date) -> Int {
        guard let deadline else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }

    /// `☕ 9:42` — minutes without a leading zero: the menu bar is narrow.
    static func title(remaining: Int) -> String {
        let s = max(0, remaining)
        return String(format: "☕ %d:%02d", s / 60, s % 60)
    }

    func start(minutes: Int = UntilBreakCountdown.startMinutes) {
        deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        overlayInfo("☕ UNTIL BREAK in the menu bar: \(minutes) min")
        run()
    }

    /// At launch: pick up a countdown a redeploy interrupted; one that ran out
    /// while the app was down is dropped silently — the moment for it is gone.
    func resumeIfPersisted() {
        guard deadline != nil else { return }
        if remaining > 0 { run() } else { deadline = nil }
    }

    /// What a ☕'s −1 landing now does (same rules the floating watch had).
    var coffeeMinute: BreakTimerModel.CoffeeMinute {
        BreakTimerModel.coffeeMinute(title: BreakTimerModel.untilBreakTitle, remaining: remaining)
    }

    func coffeePopWins(minutesInFlight: Int) -> Bool {
        BreakTimerModel.coffeePopWins(title: BreakTimerModel.untilBreakTitle,
                                      remaining: remaining, minutesInFlight: minutesInFlight)
    }

    /// A −1 landed: a minute off, the slot flashes red. Silent on purpose: the
    /// "yes!" tried on 2026-11-24 was dropped the same day (*"sună ca o cizmă"*).
    func subtractMinute() {
        guard isRunning, let d = deadline else { return }
        deadline = d.addingTimeInterval(-60)
        flashUntil = Date().addingTimeInterval(Self.flashSeconds)
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashSeconds + 0.05) { [weak self] in self?.update() }
    }

    func cancel() {
        guard isRunning else { return }
        overlayInfo("☕ UNTIL BREAK cancelled")
        stop()
    }

    @objc private func cancelAction() { cancel() }

    private func run() {
        tick?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)   // keeps counting while a menu is open
        tick = t
        update()
    }

    private func update() {
        guard isRunning else { return }
        let left = remaining
        if left <= 0 {
            overlayInfo("☕ UNTIL BREAK reached zero → the break is due")
            stop()
            onExpired?()
            return
        }
        let red = (flashUntil ?? .distantPast) > Date()
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        ]
        if red { attrs[.foregroundColor] = NSColor.systemRed }
        render?(NSAttributedString(string: Self.title(remaining: left), attributes: attrs))
    }

    private func stop() {
        tick?.invalidate(); tick = nil
        deadline = nil
        flashUntil = nil
        render?(nil)
    }
}
