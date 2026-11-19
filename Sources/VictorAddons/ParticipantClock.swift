import AppKit
import Foundation
import ScreenCaptureKit

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

    /// Whether the menu bar would draw dark text over this fill (relative
    /// luminance, the same split macOS makes between a light and a dark bar).
    static func isLight(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.6
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
/// One small borderless panel per physical screen that **hangs from the menu bar
/// like a tab**: flush under it, flush with the screen's right edge, only its
/// bottom-left corner rounded, its text ending where the menu bar clock's does.
/// Its fill is the menu bar's own colour, **sampled** from the top rows of the
/// menu bar above it (Tahoe's bar is transparent over the wallpaper, so no
/// material can imitate it), and its text is the menu bar font in the colour the
/// bar would pick for that background (Victor, same day: *"not the same look and
/// feel … as close as the menu bar, the same font as the menu bar clock"*).
/// Click-through, on every Space, never key. Checked once a second (a
/// `UserDefaults` read); repainted only when the text, the screens or the
/// visibility change; the colour is resampled on show, on a Space switch and
/// every 5 minutes.
final class ParticipantClock {
    private struct Tab {
        let panel: NSPanel
        let screen: NSScreen
        let label: NSTextField
    }
    private var tabs: [Tab] = []
    private var timer: Timer?
    private var lastText: String?
    private var lastScreens: [NSRect] = []
    /// The menu bar colour last sampled per screen frame (the frame is the key
    /// because `NSScreen` instances are replaced on every reconfiguration).
    private var barColors: [String: NSColor] = [:]
    private var lastSample = Date.distantPast

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.lastScreens = []
            self?.barColors = [:]
            self?.tick()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.sampleBarColors()
        }
        tick()
    }

    /// What `/test/participant-clock` reports.
    var snapshot: [String: Any] {
        ["shown": !tabs.isEmpty,
         "text": lastText ?? NSNull(),
         "country": BreakCountry.savedToday()?.name ?? NSNull(),
         "frames": tabs.map { t in [Int(t.panel.frame.minX), Int(t.panel.frame.minY),
                                    Int(t.panel.frame.width), Int(t.panel.frame.height)] },
         "barColors": tabs.map { t in barColors[NSStringFromRect(t.screen.frame)].map(Self.hex) ?? NSNull() as Any }]
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
        if now.timeIntervalSince(lastSample) > 300 { sampleBarColors() }
        let screens = NSScreen.physical
        let frames = screens.map(\.frame)
        guard text != lastText || frames != lastScreens || tabs.isEmpty else { return }
        let wasEmpty = tabs.isEmpty
        lastText = text
        lastScreens = frames
        hide(keepState: true)
        tabs = screens.map { makeTab(text: text, on: $0) }
        if wasEmpty { sampleBarColors() }
    }

    private func hide(keepState: Bool = false) {
        tabs.forEach { $0.panel.orderOut(nil) }
        tabs = []
        if !keepState { lastText = nil }
    }

    /// The menu bar's own font — what the clock in the corner is set in.
    static var font: NSFont { NSFont.menuBarFont(ofSize: 0) }
    /// Where the menu bar clock's last digit ends, measured on 2026-11-19 (12–13 pt
    /// from the screen's right edge on the Dells and the Retina).
    static let padRight: CGFloat = 10
    static let padLeft: CGFloat = 8
    static let height: CGFloat = 22
    static let cornerRadius: CGFloat = 7
    /// Until the first sample lands (or with no Screen Recording grant).
    static let fallbackFill = NSColor(white: 0.12, alpha: 0.92)

    private func makeTab(text: String, on screen: NSScreen) -> Tab {
        let label = MenuBarText(labelWithString: text)
        label.font = Self.font
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + Self.padLeft + Self.padRight, height: Self.height)
        // Flush under the menu bar, flush with the screen's right edge: a tab hanging from the bar.
        let origin = NSPoint(x: screen.frame.maxX - size.width, y: screen.visibleFrame.maxY - size.height)

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

        let fill = NSView(frame: NSRect(origin: .zero, size: size))
        fill.wantsLayer = true
        fill.layer?.cornerRadius = Self.cornerRadius
        fill.layer?.maskedCorners = [.layerMinXMinYCorner]   // bottom-left only; the rest touches bar and edge
        fill.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: Self.padLeft, y: (Self.height - label.frame.height) / 2)
        fill.addSubview(label)
        panel.contentView = fill
        let tab = Tab(panel: panel, screen: screen, label: label)
        paint(tab, with: barColors[NSStringFromRect(screen.frame)])
        panel.orderFrontRegardless()
        return tab
    }

    private func paint(_ tab: Tab, with bar: NSColor?) {
        let fill = bar ?? Self.fallbackFill
        tab.panel.contentView?.layer?.backgroundColor = fill.cgColor
        // Not opaque white: the bar's text is vibrant, the backdrop shows through it a little.
        tab.label.textColor = ParticipantClockPolicy.isLight(fill) ? NSColor(white: 0, alpha: 0.8) : NSColor(white: 1, alpha: 0.85)
    }

    /// Averages the top rows of the menu bar over each tab's width — above the
    /// glyphs, so the clock's own digits do not tint the average.
    private func sampleBarColors() {
        guard #available(macOS 14.0, *), !tabs.isEmpty else { return }
        lastSample = Date()
        let targets = tabs.map { (screen: $0.screen, x: $0.panel.frame.minX) }
        Task { @MainActor [weak self] in
            for t in targets {
                // 6–8 pt down and 8 pt clear of the right edge: inside Zoom's 5 pt green
                // "you are sharing" frame (it turned the Retina's tab green), still above the
                // glyphs (cap tops ~10 pt down in the 30–33 pt bars here).
                let strip = NSRect(x: t.x, y: t.screen.frame.maxY - 8, width: t.screen.frame.maxX - t.x - 8, height: 2)
                guard let color = await Self.averageColor(of: strip, on: t.screen) else { continue }
                guard let self else { return }
                self.barColors[NSStringFromRect(t.screen.frame)] = color
                for tab in self.tabs where tab.screen.frame == t.screen.frame { self.paint(tab, with: color) }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func averageColor(of box: NSRect, on screen: NSScreen) async -> NSColor? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            // Only the bar and what is under it: our own tabs, and anything layered above the
            // menu bar (Zoom's green "you are sharing" frame turned the Retina's tab green).
            let me = ProcessInfo.processInfo.processIdentifier
            let above = content.windows.filter {
                $0.windowLayer > Int(CGWindowLevelForKey(.statusWindow)) || $0.owningApplication?.processID == me
            }
            let filter = SCContentFilter(display: display, excludingWindows: above)
            let config = SCStreamConfiguration()
            let frame = screen.frame
            config.sourceRect = CGRect(x: box.minX - frame.minX, y: frame.maxY - box.maxY,
                                       width: box.width, height: box.height)
            config.width = max(1, Int(box.width.rounded()))
            config.height = max(1, Int(box.height.rounded()))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return average(image)
        } catch {
            overlayError("🕰️ menu bar colour not sampled — \(error.localizedDescription)")
            return nil
        }
    }

    private static func average(_ image: CGImage) -> NSColor? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0, g = 0, b = 0
        for i in stride(from: 0, to: px.count, by: 4) { r += Int(px[i]); g += Int(px[i + 1]); b += Int(px[i + 2]) }
        let n = CGFloat(w * h) * 255
        return NSColor(srgbRed: CGFloat(r) / n, green: CGFloat(g) / n, blue: CGFloat(b) / n, alpha: 1)
    }

    private static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255),
                      Int(s.blueComponent * 255))
    }
}

/// The bar draws its text without font smoothing ("dilation"); a label on an
/// opaque layer gets it and reads a weight heavier than the clock above it.
private final class MenuBarText: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
    }
}
