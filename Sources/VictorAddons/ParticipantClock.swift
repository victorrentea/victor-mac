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
/// visibility change. The bar is resampled on show, on a Space switch, when the
/// frontmost window moves to another screen and every 10 s: Tahoe's bar changes
/// with what is behind it and whether it is the lit one.
final class ParticipantClock {
    private struct Tab {
        let panel: NSPanel
        let screen: NSScreen
        let label: NSTextField
        let fill: NSView
    }
    private var tabs: [Tab] = []
    private var timer: Timer?
    private var lastText: String?
    private var lastScreens: [NSRect] = []
    /// The menu bar's look last sampled per screen frame (the frame is the key
    /// because `NSScreen` instances are replaced on every reconfiguration).
    private var barLooks: [String: BarLook] = [:]
    private var lastActiveScreen: String?
    private var lastSample = Date.distantPast

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.lastScreens = []
            self?.barLooks = [:]
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
         "bars": tabs.map { t in barLooks[NSStringFromRect(t.screen.frame)].map {
             ["fill": Self.hex($0.fill), "lightText": $0.lightText, "ink": Double($0.inkStrength)] as [String: Any]
         } ?? NSNull() as Any }]
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
        let active = Self.activeScreenKey()
        if active != lastActiveScreen {
            lastActiveScreen = active
            // The lit menu bar moved: undim one tab, dim another. macOS animates the
            // change, so sample again once it has settled.
            sampleBarColors()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.sampleBarColors() }
        } else if now.timeIntervalSince(lastSample) > 10 {
            sampleBarColors()
        }
        // Never on the built-in Retina (Victor: "nu mai pune pe retina deloc"): its bar
        // fades into what is below it and no flat tab under it looked right. The Retina
        // alone → no clock at all.
        let screens = NSScreen.physical.filter { !Self.isBuiltin($0) }
        guard !screens.isEmpty else { hide(); return }
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
    static let padRight: CGFloat = 8.5
    static let padLeft: CGFloat = 8
    static let height: CGFloat = 22
    /// How far the tab reaches up into a bar this tall: the clock's digits end ~5 pt
    /// below the bar's middle; this puts ours one line of 13 pt text under them
    /// (~6.5 pt between the two rows of digits).
    static func overlap(barHeight: CGFloat) -> CGFloat { max(0, (barHeight / 2 - 5).rounded()) }
    static let cornerRadius: CGFloat = 7
    /// Until the first sample lands (or with no Screen Recording grant).
    static let fallbackFill = NSColor(white: 0.12, alpha: 0.92)

    private func makeTab(text: String, on screen: NSScreen) -> Tab {
        let label = NSTextField(labelWithString: text)
        label.font = Self.font
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + Self.padLeft + Self.padRight, height: Self.height)
        // Its top reaches up into the bar, just under the clock's digits (centred in the bar,
        // ~5 pt below the middle), so the two read as two lines of one clock.
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let overlap = Self.overlap(barHeight: barHeight)
        let origin = NSPoint(x: screen.frame.maxX - size.width, y: screen.visibleFrame.maxY + overlap - size.height)

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

        // Clear where it lies on the bar (the real bar, gradient and all, shows through);
        // filled with the bar's bottom colour only below it, bottom-left corner rounded.
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let fill = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - overlap))
        fill.wantsLayer = true
        fill.layer?.cornerRadius = Self.cornerRadius
        fill.layer?.maskedCorners = [.layerMinXMinYCorner]   // bottom-left only; the rest touches bar and edge
        fill.layer?.masksToBounds = true
        root.addSubview(fill)
        label.frame.origin = NSPoint(x: Self.padLeft, y: (Self.height - label.frame.height) / 2)
        root.addSubview(label)
        panel.contentView = root
        let tab = Tab(panel: panel, screen: screen, label: label, fill: fill)
        paint(tab, with: barLooks[NSStringFromRect(screen.frame)])
        panel.orderFrontRegardless()
        return tab
    }

    private func paint(_ tab: Tab, with look: BarLook?) {
        tab.fill.layer?.backgroundColor = (look?.fill ?? Self.fallbackFill).cgColor
        // Full-strength ink faded by the panel's alpha, so the flag fades with the
        // digits — the same blend macOS uses to dim an inactive screen's bar.
        tab.label.textColor = (look?.lightText ?? true) ? .white : .black
        tab.label.alphaValue = look?.inkStrength ?? 1
    }

    private static func isBuiltin(_ screen: NSScreen) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// One capture of the bar over each tab's width gives everything the tab copies:
    /// the colour the bar ends with (the fill below it), and the clock's own ink —
    /// how bright it is against the bar says whether this screen's menu bar is the
    /// active one (macOS dims the text of the others) and whether the bar is light.
    private func sampleBarColors() {
        guard #available(macOS 14.0, *), !tabs.isEmpty else { return }
        lastSample = Date()
        let targets = tabs.map { (screen: $0.screen, x: $0.panel.frame.minX) }
        Task { @MainActor [weak self] in
            for t in targets {
                let bottom = t.screen.visibleFrame.maxY
                let bar = NSRect(x: t.x, y: bottom, width: t.screen.frame.maxX - t.x, height: t.screen.frame.maxY - bottom)
                guard let image = await Self.capture(bar, on: t.screen),
                      let look = BarLook(image, barHeight: bar.height, scale: t.screen.backingScaleFactor) else { continue }
                guard let self else { return }
                self.barLooks[NSStringFromRect(t.screen.frame)] = look
                for tab in self.tabs where tab.screen.frame == t.screen.frame { self.paint(tab, with: look) }
            }
        }
    }

    /// The screen whose menu bar is lit: the one holding the frontmost app's
    /// frontmost window. Polled with the tick, a change resamples at once.
    private static func activeScreenKey() -> String? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid
            && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let mid = CGPoint(x: (b["X"] ?? 0) + (b["Width"] ?? 0) / 2, y: (b["Y"] ?? 0) + (b["Height"] ?? 0) / 2)
            // CG's origin is the primary screen's top-left; flip into AppKit's.
            let flipped = NSPoint(x: mid.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - mid.y)
            return NSScreen.screens.first { $0.frame.contains(flipped) }.map { NSStringFromRect($0.frame) }
        }
        return nil
    }

    @available(macOS 14.0, *)
    private static func capture(_ box: NSRect, on screen: NSScreen) async -> CGImage? {
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
            config.width = max(1, Int((box.width * screen.backingScaleFactor).rounded()))
            config.height = max(1, Int((box.height * screen.backingScaleFactor).rounded()))
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            overlayError("🕰️ menu bar not sampled — \(error.localizedDescription)")
            return nil
        }
    }

    private static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255),
                      Int(s.blueComponent * 255))
    }
}


/// What a tab copies from the bar above it, read off one capture of it.
struct BarLook {
    /// The bar's colour 4–6 pt above its bottom edge (its last rows carry a
    /// darker line), the right 8 pt left out — what continues below the bar.
    let fill: NSColor
    /// Whether the clock is drawn light on this bar (Tahoe flips to dark ink on a light one).
    let lightText: Bool
    /// The clock ink's contrast against the bar, relative to pure white/black on
    /// it: ~1 on the lit menu bar, ~0.5 on the dimmed ones.
    let inkStrength: CGFloat

    init?(_ image: CGImage, barHeight: CGFloat, scale: CGFloat) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Row 0 of `px` is the top of the bar.
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * w + x) * 4
            return (Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
        }
        let right = max(1, w - Int(8 * scale))
        let y0 = max(0, h - Int(6 * scale)), y1 = max(y0 + 1, h - Int(4 * scale))
        var s = (0.0, 0.0, 0.0), n = 0.0
        for y in y0..<min(y1, h) { for x in 0..<right { let c = rgb(x, y); s.0 += c.0; s.1 += c.1; s.2 += c.2; n += 1 } }
        guard n > 0 else { return nil }
        let fill = (s.0 / n, s.1 / n, s.2 / n)
        // The clock's digits: the last ~50 pt of the bar, 3 pt in from its edges.
        let left = max(0, w - Int(50 * scale))
        let top = Int(3 * scale), low = max(top + 1, h - Int(3 * scale))
        var bg = (0.0, 0.0, 0.0), m = 0.0
        for y in top..<low { for x in left..<right { let c = rgb(x, y); bg.0 += c.0; bg.1 += c.1; bg.2 += c.2; m += 1 } }
        guard m > 0 else { return nil }
        bg = (bg.0 / m, bg.1 / m, bg.2 / m)
        func luma(_ c: (Double, Double, Double)) -> Double { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }
        var ink = bg, far = 0.0
        for y in top..<low { for x in left..<right {
            let c = rgb(x, y), d = abs(luma(c) - luma(bg))
            if d > far { far = d; ink = c }
        } }
        let light = luma(ink) >= luma(bg)
        let room = light ? 1 - luma(bg) : luma(bg)
        self.fill = NSColor(srgbRed: fill.0, green: fill.1, blue: fill.2, alpha: 1)
        self.lightText = light
        self.inkStrength = room > 0.05 ? CGFloat(min(1, max(0.3, far / room))) : 1
    }
}
