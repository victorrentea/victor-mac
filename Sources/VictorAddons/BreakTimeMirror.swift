import AppKit

/// Which screens get a ☕ copy of the break's time left: every one a PowerPoint
/// window fills edge to edge (Slide Show, Presenter View, a full-screen editor —
/// the menu bar is gone there), except the one the watch itself is on.
enum BreakTimeMirrorPolicy {
    /// `displays` and `fullWindows` are CoreGraphics rects (top-left origin), so
    /// a window covering a display has exactly the display's bounds.
    static func screens(displays: [(id: CGDirectDisplayID, bounds: CGRect)],
                        powerPointWindows: [CGRect],
                        watchDisplay: CGDirectDisplayID?) -> [CGDirectDisplayID] {
        displays.filter { d in
            d.id != watchDisplay && powerPointWindows.contains { covers($0, d.bounds) }
        }.map(\.id)
    }

    /// Within a point: PowerPoint lands on whole points, Quartz may hand back halves.
    static func covers(_ window: CGRect, _ display: CGRect) -> Bool {
        abs(window.minX - display.minX) <= 1 && abs(window.minY - display.minY) <= 1
            && window.width >= display.width - 1 && window.height >= display.height - 1
    }

    /// `☕ 06:51`, `☕ 06:51 ⏸` while paused.
    static func title(remaining: Int, paused: Bool) -> String {
        "☕ " + BreakTimerModel.format(remaining: remaining) + (paused ? " ⏸" : "")
    }
}

/// ☕ **The break's time left, on the screens PowerPoint covers** (2026-11-24,
/// Victor: *"timpul rămas … să apară chiar dacă sunt cu PowerPoint-ul în
/// fullscreen. Măcar pe ecranul doi … ar fi bine pe ambele"*).
///
/// The watch is one panel on one screen — the Retina, mirrored to the room.
/// Starting a show puts Presenter View over the other screen and takes its menu
/// bar (and the 🧠 slot's ☕) with it, so the time left vanished from where
/// Victor looks. A click-through pill at the top centre of each such screen
/// brings it back, only while a real break runs; the watch itself already sits
/// at `.maximumWindow`, over the slides.
///
/// Polled once a second — the same pace the digits change at; the window list is
/// read only while a break is up. No Screen Recording needed: bounds, not titles.
final class BreakTimeMirror {
    private let breakState: () -> (remaining: Int, paused: Bool, screen: NSScreen?)?
    private var pills: [CGDirectDisplayID: NSPanel] = [:]
    private var timer: Timer?
    /// Each second, whether a real break is up — the 🧠 slot shows ☕ meanwhile.
    var onBreakActive: ((Bool) -> Void)?
    private var lastActive: Bool?

    init(breakState: @escaping () -> (remaining: Int, paused: Bool, screen: NSScreen?)?) {
        self.breakState = breakState
    }

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        let state = breakState()
        let active = state != nil
        if active != lastActive {
            lastActive = active
            onBreakActive?(active)
        }
        guard let state else { return removeAll() }

        let watchDisplay = state.screen.flatMap(Self.displayID)
        let displays = NSScreen.physical.compactMap(Self.displayID)
            .map { (id: $0, bounds: CGDisplayBounds($0)) }
        let wanted = Set(BreakTimeMirrorPolicy.screens(displays: displays,
                                                        powerPointWindows: Self.powerPointWindows(),
                                                        watchDisplay: watchDisplay))
        for (id, p) in pills where !wanted.contains(id) {
            p.orderOut(nil)
            pills[id] = nil
        }
        let title = BreakTimeMirrorPolicy.title(remaining: state.remaining, paused: state.paused)
        for id in wanted {
            guard let screen = NSScreen.physical.first(where: { Self.displayID($0) == id }) else { continue }
            let pill = pills[id] ?? makePill()
            pills[id] = pill
            (pill.contentView as? PillView)?.text = title
            pill.setFrame(Self.frame(on: screen), display: true)
            pill.orderFrontRegardless()
        }
    }

    private func removeAll() {
        for p in pills.values { p.orderOut(nil) }
        pills = [:]
    }

    /// Top centre, clear of Presenter View's toolbar labels on the left.
    private static func frame(on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let size = NSSize(width: 210, height: 48)
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 6,
                      width: size.width, height: size.height)
    }

    private func makePill() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = PillView()
        return p
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// On-screen, normal-layer PowerPoint windows, in CoreGraphics coordinates.
    private static func powerPointWindows() -> [CGRect] {
        guard let pid = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.microsoft.Powerpoint").first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { return nil }
            return rect
        }
    }

    private final class PillView: NSView {
        var text = "" { didSet { if text != oldValue { needsDisplay = true } } }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            NSColor.black.withAlphaComponent(0.85).setFill()
            path.fill()
            NSColor.systemRed.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 2
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
    }
}
