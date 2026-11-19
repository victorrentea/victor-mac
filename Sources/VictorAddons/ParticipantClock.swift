import AppKit
import Foundation

/// The pure half of 🕰️: whether the participants' clock shows, and what it says.
enum ParticipantClockPolicy {
    /// Shown only when the participants' wall clock reads differently from this
    /// Mac's — same offset (Romania at home, Greece, …) would be a second copy of
    /// the menu bar clock.
    static func isShown(participants: TimeZone?, local: TimeZone, at date: Date) -> Bool {
        guard let participants else { return false }
        return participants.secondsFromGMT(for: date) != local.secondsFromGMT(for: date)
    }

    /// The menu bar clock's own hour style: `H:mm` on a 24 h Mac, `h:mm` on a
    /// 12 h one — the menu bar drops the AM/PM, so this does too (it read `1:08`
    /// on 2026-11-19).
    static var systemTimeFormat: String {
        let f = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: .current) ?? "HH:mm"
        return f.replacingOccurrences(of: "a", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// `🇵🇹 11:05`, or `🇵🇹 Thu 23:05` when their day is not ours — in the menu
    /// bar clock's hour style, the weekday only when it says something.
    static func label(flag: String, participants: TimeZone, local: TimeZone, at date: Date,
                      timeFormat: String = "HH:mm") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = participants
        f.dateFormat = "yyyy-MM-dd"
        let theirDay = f.string(from: date)
        f.timeZone = local
        let ourDay = f.string(from: date)
        f.timeZone = participants
        f.dateFormat = theirDay == ourDay ? timeFormat : "EEE " + timeFormat
        return "\(flag) \(f.string(from: date))"
    }
}

/// 🕰️ **The participants' time, under the menu bar clock** (2026-11-19, Victor:
/// *"un ceas mic chiar sub ceasul oficial din colț, cu ora participanților"*).
///
/// The participants' zone is the one the ☕️ Break country picker holds for today
/// (`BreakCountry.savedToday`: a manual pick, or the auto-pick of the day's first
/// break). Nothing stored today, or a zone whose clock reads like ours → no clock.
///
/// One small borderless panel per physical screen, top-right, flush under the
/// menu bar where the system clock sits, in the menu bar's own font (system 13,
/// monospaced digits) on the menu material — so it reads as a second line of the
/// same clock, not an overlay. Click-through, on every Space, never key.
/// Checked once a second (a `UserDefaults` read); repainted only when the text,
/// the screens or the visibility change.
final class ParticipantClock {
    private var panels: [NSPanel] = []
    private var timer: Timer?
    private var lastText: String?
    private var lastScreens: [NSRect] = []

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.lastScreens = []
            self?.tick()
        }
        tick()
    }

    /// What `/test/participant-clock` reports.
    var snapshot: [String: Any] {
        ["shown": !panels.isEmpty,
         "text": lastText ?? NSNull(),
         "country": BreakCountry.savedToday()?.name ?? NSNull(),
         "frames": panels.map { p in [Int(p.frame.minX), Int(p.frame.minY), Int(p.frame.width), Int(p.frame.height)] }]
    }

    func tick() {
        let now = Date()
        let country = BreakCountry.savedToday()
        guard let country,
              ParticipantClockPolicy.isShown(participants: country.timeZone, local: .current, at: now) else {
            hide()
            return
        }
        let text = ParticipantClockPolicy.label(flag: country.flag, participants: country.timeZone,
                                                local: .current, at: now,
                                                timeFormat: ParticipantClockPolicy.systemTimeFormat)
        let screens = NSScreen.physical
        let frames = screens.map(\.frame)
        guard text != lastText || frames != lastScreens || panels.isEmpty else { return }
        lastText = text
        lastScreens = frames
        hide(keepState: true)
        panels = screens.map { makePanel(text: text, on: $0) }
    }

    private func hide(keepState: Bool = false) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        if !keepState { lastText = nil }
    }

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    private func makePanel(text: String, on screen: NSScreen) -> NSPanel {
        let label = NSTextField(labelWithString: text)
        label.font = Self.font
        label.textColor = .labelColor
        label.sizeToFit()
        let padX: CGFloat = 7, height: CGFloat = 20
        let size = NSSize(width: ceil(label.frame.width) + padX * 2, height: height)
        // Right edge where the menu bar clock ends; top flush under the menu bar.
        let menuBarBottom = screen.visibleFrame.maxY
        let origin = NSPoint(x: screen.frame.maxX - size.width - 6, y: menuBarBottom - size.height - 2)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 6
        material.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: padX, y: (height - label.frame.height) / 2)
        material.addSubview(label)
        panel.contentView = material
        panel.orderFrontRegardless()
        return panel
    }
}
