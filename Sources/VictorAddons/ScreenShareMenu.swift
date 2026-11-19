import AppKit
import Foundation

/// The pure half of 📡: when the screen-share item is on the bar, and what it says.
enum ScreenShareMenuPolicy {
    /// Why the item is showing — also its tooltip, so the bar never shows an icon
    /// whose reason has to be guessed.
    enum Reason: String {
        case sharing      // Zoom or Teams is sharing the screen right now
        case meetingApp   // Zoom or Teams is running
        case external     // a projector / HDMI / the ASUS is plugged in
    }

    /// Strongest reason first: a live share outranks an open meeting app, which
    /// outranks a cable. Nil = nothing is being or about to be shared: no item.
    static func reason(externalScreens: Int, meetingAppRunning: Bool, sharing: Bool) -> Reason? {
        if sharing { return .sharing }
        if meetingAppRunning { return .meetingApp }
        if externalScreens > 0 { return .external }
        return nil
    }

    static func tooltip(_ reason: Reason, externalScreens: Int) -> String {
        switch reason {
        case .sharing: return "Sharing your screen in Zoom/Teams"
        case .meetingApp: return "Zoom/Teams is open — ready to share"
        case .external: return externalScreens == 1 ? "An external screen is connected" : "\(externalScreens) external screens are connected"
        }
    }

    static let meetingBundleIDs: Set<String> = Set(["us.zoom.xos"] + TeamsMeetingLayout.bundleIDs)
}

/// 📡 **Everything about sharing the screen, in its own menu bar item** (2026-11-19,
/// Victor: *"tot ce ține de screen sharing … un item separat de meniu care apare
/// când e detectat sharing"*).
///
/// The screens-and-meetings section left 💬 for this one: Arrange Monitors, the
/// ◀ ASUS ▶ flip, 🎥 Layout Zoom/Teams, 🖥️ PowerPoint Presenter View, 🔊 Auto
/// Share Faceover, 🎞️ Retina 60 Hz, 🔻 Retina 1× and 🔊 Teams Share with Sound.
/// Same process, same settings, same code paths — only the rows moved.
///
/// The item **exists only while something is shared or about to be**
/// (`ScreenShareMenuPolicy`): an external screen (projector, HDMI, the ASUS),
/// Zoom or Teams running, or a live share seen by `MeetingShareWatch`. A live
/// share draws a red dot on the icon. Like 🖥️ VM (`TartVMIndicator`) it is
/// created and removed, never `isVisible`-toggled: a hidden status item is a
/// preference macOS remembers, and a removed one cannot get stuck hidden.
///
/// Every toggle acts on its own when the moment comes, so it is never *needed*
/// to open this menu; the defaults keep working while the item is gone.
final class ScreenShareMenu: NSObject, NSMenuDelegate {
    var onFixDisplayLayout: (() -> Void)?
    var asusState: (() -> AsusSide.State)?
    var onPlaceAsus: ((AsusSide) -> Void)?
    var onLayoutZoom: (() -> Void)?
    /// 🎞️ Retina 60 Hz ticked/unticked: cap or give the refresh back now.
    var onToggleRetinaCap: (() -> Void)?
    /// 🔻 Retina 1× while sharing ticked/unticked: drop or give the resolution back now.
    var onToggleRetinaShareRes: (() -> Void)?
    /// Whether Zoom/Teams is sharing right now (`MeetingShareWatch.isSharing`).
    var isSharing: (() -> Bool)?

    /// `/test/share-menu?force=on|off` pins the item for a headless check; nil = live.
    var forced: Bool?

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var timer: Timer?
    private(set) var reason: ScreenShareMenuPolicy.Reason?
    private var shownSharing = false

    func start() {
        menu.delegate = self
        menu.autoenablesItems = false
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(changed), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(changed), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(changed), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // The share itself has no notification; MeetingShareWatch polls, so do we (cheap: no AX, no window list).
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    @objc private func changed() { DispatchQueue.main.async { [weak self] in self?.refresh() } }

    static func externalScreenCount() -> Int {
        NSScreen.physical.filter { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(id.uint32Value) == 0
        }.count
    }

    static func meetingAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier.map(ScreenShareMenuPolicy.meetingBundleIDs.contains) ?? false
        }
    }

    func refresh() {
        let external = Self.externalScreenCount()
        let sharing = isSharing?() ?? false
        var r = ScreenShareMenuPolicy.reason(externalScreens: external,
                                             meetingAppRunning: Self.meetingAppRunning(),
                                             sharing: sharing)
        if let forced { r = forced ? (r ?? .external) : nil }
        reason = r
        guard let r else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            statusItem = item
            shownSharing = !sharing   // force the first paint
        }
        if shownSharing != sharing {
            shownSharing = sharing
            statusItem?.button?.image = Self.icon(live: sharing)
        }
        statusItem?.button?.toolTip = ScreenShareMenuPolicy.tooltip(r, externalScreens: external)
    }

    var isShown: Bool { statusItem != nil }

    // MARK: - Icon

    /// Two overlapping screens — the macOS Screen Mirroring glyph, the one sign
    /// for "this screen goes somewhere else". Template, so it follows the bar;
    /// a live share adds a red dot, drawn into a non-template copy.
    static func icon(live: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Screen sharing")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? NSImage()
        guard live else { base.isTemplate = true; return base }
        let size = NSSize(width: base.size.width + 4, height: max(base.size.height, 14))
        let image = NSImage(size: size, flipped: false) { rect in
            // The bar's ink, since a non-template image is drawn as-is.
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let ink = dark ? NSColor.white : NSColor.black
            let tinted = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                ink.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: 0, y: (rect.height - base.size.height) / 2,
                                   width: base.size.width, height: base.size.height))
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Menu

    /// Built fresh on every open: every tick is read from its setting there, so
    /// a test hook or another path flipping a setting can never leave a stale tick.
    func menuNeedsUpdate(_ menu: NSMenu) { build() }

    private func build() {
        menu.removeAllItems()

        if let reason {
            let header = NSMenuItem(title: ScreenShareMenuPolicy.tooltip(reason, externalScreens: Self.externalScreenCount()),
                                    action: nil, keyEquivalent: "")
            header.image = MenuBarManager.emojiIcon(reason == .sharing ? "🔴" : "📡")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }

        // Where the screens go — wanted in a hurry, mid-talk.
        add("Arrange Monitors", icon: MenuBarManager.emojiIcon("🖥️"), action: #selector(fixDisplayLayoutAction))
        // Only the move that would change something; neither while the ASUS is absent or mirroring.
        let asus = asusState?() ?? .absent
        if asus == .at(.right) {
            add("◀\u{FE0E} ASUS left", icon: MenuBarManager.emojiIcon("🖥️"), action: #selector(placeAsusLeftAction))
        } else if asus == .at(.left) {
            add("ASUS ▶\u{FE0E} right", icon: MenuBarManager.emojiIcon("🖥️"), action: #selector(placeAsusRightAction))
        }
        // 🎥 Named after the meeting app that runs; absent when none does.
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let zoom = ids.contains("us.zoom.xos")
        let teams = !ids.isDisjoint(with: TeamsMeetingLayout.bundleIDs)
        if zoom || teams {
            add(zoom && teams ? "Layout Meeting" : teams ? "Layout Teams" : "Layout Zoom",
                icon: Self.zoomLayoutIcon, action: #selector(layoutZoomAction))
        }

        // What acts on its own when a slide show or a share starts.
        menu.addItem(.separator())
        add(MenuBarManager.ticked(Self.pptPresenterTitle, PowerPointPresenterSettings.isEnabled),
            icon: MenuBarManager.emojiIcon("🖥️"), action: #selector(togglePptPresenterAction))
        add(MenuBarManager.ticked(Self.faceoverTitle, ZoomSharePrepSettings.isEnabled),
            icon: Self.faceoverIcon, action: #selector(toggleZoomSharePrepAction),
            tip: "When Zoom's share picker opens: tick Share sound, pick “As background” with you cut out bottom-right, select the Retina and press Share. Hold ⌥ while opening the picker to choose yourself.")
        add(MenuBarManager.ticked(Self.teamsShareSoundTitle, TeamsShareSoundSettings.isEnabled),
            icon: MenuBarManager.emojiIcon("🔊"), action: #selector(toggleTeamsShareSoundAction),
            tip: "When Teams' Share content flyout opens, tick Include sound. Untick it by hand and it stays off until the flyout is reopened.")
        add(MenuBarManager.ticked(Self.retinaCapTitle, RetinaRefreshCapSettings.isEnabled),
            icon: MenuBarManager.emojiIcon("🎞️"), action: #selector(toggleRetinaCapAction),
            tip: "While Zoom or Teams runs, the Retina refreshes at 60 Hz at most (120 Hz ProMotion otherwise). The share and the projector never get more than 60. Given back when the last of them quits.")
        add(MenuBarManager.ticked(Self.retinaShareResTitle, RetinaShareResolutionSettings.isEnabled),
            icon: MenuBarManager.emojiIcon("🔻"), action: #selector(toggleRetinaShareResAction),
            tip: "While Zoom or Teams shares, the Retina runs at 1× (1728×1118 px instead of 3456×2234) — same layout, nothing moves, but WindowServer captures 4.4× fewer pixels per frame, so the cursor stops lagging. The panel looks softer meanwhile; the Retina mode comes back when the share ends.")
    }

    /// Row titles as the menu would show them — `/test/share-menu` reports them.
    func rowTitles() -> [String] {
        build()
        return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @discardableResult
    private func add(_ title: String, icon: NSImage, action: Selector, tip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.image = icon
        item.toolTip = tip
        menu.addItem(item)
        return item
    }

    /// Test hook: open the menu as a click would, closing itself after `seconds`
    /// (armed before the click: the main queue is not drained while a menu tracks).
    func openForTest(closeAfter seconds: TimeInterval) {
        guard let button = statusItem?.button else { return }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.menu.cancelTracking() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        button.performClick(nil)
    }

    // MARK: - Actions

    @objc private func fixDisplayLayoutAction() { onFixDisplayLayout?() }
    @objc private func placeAsusLeftAction() { onPlaceAsus?(.left) }
    @objc private func placeAsusRightAction() { onPlaceAsus?(.right) }
    @objc private func layoutZoomAction() { onLayoutZoom?() }

    /// Notifies nobody: `PowerPointPresenterPlacement` reads the setting on each scan.
    @objc private func togglePptPresenterAction() { PowerPointPresenterSettings.isEnabled.toggle() }
    /// Notifies nobody: `ZoomSharePrep` reads the setting on each scan.
    @objc private func toggleZoomSharePrepAction() { ZoomSharePrepSettings.isEnabled.toggle() }
    @objc private func toggleTeamsShareSoundAction() { TeamsShareSoundSettings.isEnabled.toggle() }
    /// Acts on the tick: a capped Retina is given back now.
    @objc private func toggleRetinaCapAction() {
        RetinaRefreshCapSettings.isEnabled.toggle()
        onToggleRetinaCap?()
    }
    /// Acts on the tick, like 🎞️: a dropped Retina is given back now.
    @objc private func toggleRetinaShareResAction() {
        RetinaShareResolutionSettings.isEnabled.toggle()
        onToggleRetinaShareRes?()
    }

    static let faceoverTitle = "Auto Share Faceover"
    static let retinaCapTitle = "Retina 60 Hz in Zoom/Teams"
    static let retinaShareResTitle = "Retina 1× while sharing"
    static let teamsShareSoundTitle = "Teams Share with Sound"
    static let pptPresenterTitle = "PowerPoint Presenter View → left screen"

    /// A screen with a framed head-and-shoulders in its bottom-right corner — the
    /// "As background" share 🔊 Auto Share Faceover sets up. Template image.
    static let faceoverIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let screen = rect.insetBy(dx: 1, dy: 1.5)
            let outline = NSBezierPath(roundedRect: screen, xRadius: 1.5, yRadius: 1.5)
            outline.lineWidth = 1.2
            outline.stroke()
            // The cut-out's frame, flush with the bottom-right corner.
            let face = NSRect(x: screen.maxX - 8, y: screen.minY, width: 8, height: 6.5)
            let frame = NSBezierPath(rect: face)
            frame.lineWidth = 1
            frame.stroke()
            // Head and shoulders inside it.
            NSBezierPath(ovalIn: NSRect(x: face.midX - 1.4, y: face.minY + 2.6, width: 2.8, height: 2.8)).fill()
            let shoulders = NSBezierPath()
            shoulders.appendArc(withCenter: NSPoint(x: face.midX, y: face.minY), radius: 2.6,
                                startAngle: 0, endAngle: 180)
            shoulders.close()
            shoulders.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// ▥ — what 🎥 Layout Zoom does to the monitor above the Retina, as a template
    /// image so it follows the menu's light/dark appearance.
    static let zoomLayoutIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { rect in
            let frame = rect.insetBy(dx: 1, dy: 1.5)
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: frame, xRadius: 1.5, yRadius: 1.5)
            outline.lineWidth = 1.2
            outline.stroke()
            let split = frame.minX + frame.width * 0.6
            let lines = NSBezierPath()
            lines.move(to: NSPoint(x: split, y: frame.minY))
            lines.line(to: NSPoint(x: split, y: frame.maxY))
            lines.move(to: NSPoint(x: split, y: frame.midY))
            lines.line(to: NSPoint(x: frame.maxX, y: frame.midY))
            lines.lineWidth = 1.2
            lines.stroke()
            // The meeting pane, filled: the big picture is the video.
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: NSRect(x: frame.minX + 1.5, y: frame.minY + 1.5,
                                      width: split - frame.minX - 3, height: frame.height - 3)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
