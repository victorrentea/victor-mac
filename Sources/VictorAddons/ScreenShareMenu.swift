import AppKit
import Foundation

/// The pure half of 📡: when the screen-share item is on the bar, and what it says.
enum ScreenShareMenuPolicy {
    /// Why the item is showing — also its tooltip, so the bar never shows an icon
    /// whose reason has to be guessed.
    enum Reason: String {
        case sharing      // Zoom or Teams is sharing the screen right now
        case meetingApp   // Zoom or Teams is running
        case virtualDesktop // 🪞 Victor Mirror's invisible screen is up
        case external     // a projector / HDMI / the ASUS is plugged in
    }

    /// Strongest reason first: a live share outranks an open meeting app, which
    /// outranks a cable. Nil = nothing is being or about to be shared: no item.
    static func reason(externalScreens: Int, meetingAppRunning: Bool, sharing: Bool,
                       virtualDesktopUp: Bool = false) -> Reason? {
        if sharing { return .sharing }
        if meetingAppRunning { return .meetingApp }
        // Up without Zoom/Teams only when switched on by hand — its row must stay reachable.
        if virtualDesktopUp { return .virtualDesktop }
        if externalScreens > 0 { return .external }
        return nil
    }

    static func tooltip(_ reason: Reason, externalScreens: Int) -> String {
        switch reason {
        case .sharing: return "Sharing your screen in Zoom/Teams"
        case .meetingApp: return "Zoom/Teams is open — ready to share"
        case .virtualDesktop: return "🪞 Virtual Desktop is up"
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
/// Share Faceover, 🎞️ Retina 60 Hz, 🔻 Retina Default while sharing and 🔊 Teams Share with Sound.
/// Same process, same settings, same code paths — only the rows moved.
///
/// **🪞 Victor Mirror's two rows joined the same day** (Victor: *"merge the
/// virtual desktop thingy with the new sharing screen menu item"*): Virtual
/// Desktop and its Auto-start on Zoom/Teams. Mirror stays a separate process, so
/// that redeploying this one never kills the 🪞 screen or the share on it; it
/// just lost its own menu bar item. The rows are drawn from `/virtual-desktop`
/// on 55127, fetched in the background with every refresh, and are absent while
/// Mirror does not answer.
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
    /// 🔻 Retina Default while sharing ticked/unticked: switch or give the resolution back now.
    var onToggleRetinaShareRes: (() -> Void)?
    /// Whether Zoom/Teams is sharing right now (`MeetingShareWatch.isSharing`).
    var isSharing: (() -> Bool)?

    /// `/test/share-menu?force=on|off` pins the item for a headless check; nil = live.
    var forced: Bool?

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var timer: Timer?
    private(set) var reason: ScreenShareMenuPolicy.Reason?
    /// The icon drawn last (live or not); nil = none drawn yet.
    private var shownLive: Bool?
    /// 🪞 Victor Mirror's last answer; nil = not running / not answering.
    private(set) var mirror: MirrorProxy.VirtualDesktopState?

    /// Creates the item, hidden, **before the 💬 V's own item** (AppDelegate calls
    /// this right before `MenuBarManager.setup()`): an item created earlier sits
    /// further right, so the 📡 screens land just right of the V — Victor wants the
    /// two side by side (2026-11-19). It is then only ever hidden (`isVisible`),
    /// never removed: a re-created item would come back at the far left of the
    /// bar, away from the V. The autosave name keeps its slot across restarts.
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "screen-share"
        item.menu = menu
        item.isVisible = false
        statusItem = item
        shownLive = nil
    }

    func start() {
        install()
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

    /// Re-evaluates now, and asks Victor Mirror for its state on the side.
    func refresh() {
        apply()
        MirrorProxy.virtualDesktop { [weak self] state in
            guard let self, state != self.mirror else { return }
            self.mirror = state
            self.apply()
        }
    }

    private func apply() {
        let external = Self.externalScreenCount()
        let sharing = isSharing?() ?? false
        var r = ScreenShareMenuPolicy.reason(externalScreens: external,
                                             meetingAppRunning: Self.meetingAppRunning(),
                                             sharing: sharing,
                                             virtualDesktopUp: mirror?.up ?? false)
        if let forced { r = forced ? (r ?? .external) : nil }
        reason = r
        guard let r else {
            if statusItem?.isVisible == true { statusItem?.isVisible = false }
            return
        }
        if statusItem?.isVisible == false {
            Self.pinRightOfV()
            statusItem?.isVisible = true
        }
        if shownLive != sharing {
            shownLive = sharing
            statusItem?.button?.image = Self.icon(live: sharing)
        }
        statusItem?.button?.toolTip = ScreenShareMenuPolicy.tooltip(r, externalScreens: external)
    }

    var isShown: Bool { statusItem?.isVisible ?? false }

    /// macOS keeps each named item's slot in this app's defaults as
    /// `NSStatusItem Preferred Position <autosaveName>`, in points counted from the
    /// right (smaller = further right), and **drops the key when the item is hidden**
    /// — re-shown with no key, the item lands at the far left of the bar. So before
    /// every show the 📡 slot is written one point right of the V's: it reappears
    /// glued to the V, wherever Victor has ⌘-dragged the V (measured 2026-11-19).
    static func pinRightOfV() {
        let d = UserDefaults.standard
        guard let v = d.object(forKey: "NSStatusItem Preferred Position victor-v") as? Double else { return }
        d.set(v - 1, forKey: "NSStatusItem Preferred Position screen-share")
    }

    // MARK: - Icon

    /// Two overlapping screens — the macOS Screen Mirroring glyph, the one sign
    /// for "this screen goes somewhere else" — drawn by hand a notch larger than
    /// the SF symbol (22×18 instead of 21×16), with **the V of the 💬 item's logo
    /// filling the front screen, centred**, so the eye finds *this app's* item
    /// among the bar's other screen glyphs (Victor, 2026-11-19).
    /// Template, so it follows the bar; a live share adds a red dot, drawn into a
    /// non-template copy in the bar's ink.
    static func icon(live: Bool) -> NSImage {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink: NSColor = live ? (dark ? .white : .black) : .black
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let line: CGFloat = 1.4
            let back = NSRect(x: 1, y: 6.5, width: 14.5, height: 10.5)
            let front = NSRect(x: 5, y: 1, width: 15.5, height: 11.5)
            ink.setStroke()
            let b = NSBezierPath(roundedRect: back, xRadius: 2.5, yRadius: 2.5)
            b.lineWidth = line
            b.stroke()
            // The front screen hides the back one: punch its footprint (plus a
            // stroke's gap) out of what is drawn so far.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: front.insetBy(dx: -line, dy: -line), xRadius: 3.5, yRadius: 3.5).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let f = NSBezierPath(roundedRect: front, xRadius: 2.5, yRadius: 2.5)
            f.lineWidth = line
            f.stroke()
            let v = NSBezierPath()
            v.move(to: NSPoint(x: front.midX - 3.6, y: front.midY + 3.0))
            v.line(to: NSPoint(x: front.midX, y: front.midY - 3.0))
            v.line(to: NSPoint(x: front.midX + 3.6, y: front.midY + 3.0))
            v.lineWidth = 1.5
            v.lineCapStyle = .round
            v.lineJoinStyle = .round
            v.stroke()
            if live {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: size.width - 7, y: size.height - 7, width: 7, height: 7)).fill()
            }
            return true
        }
        image.isTemplate = !live
        image.accessibilityDescription = "Screen sharing"
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

        // 🪞 Victor Mirror's screen, the one shared in place of the Retina.
        if let mirror {
            add(MenuBarManager.ticked(Self.virtualDesktopTitle, mirror.up),
                icon: MenuBarManager.emojiIcon("🪞"), action: #selector(toggleVirtualDesktopAction),
                tip: "An invisible screen with the Retina and you cut out bottom-right. Share that screen in Teams/Zoom. On the Retina you see only your faint 20% shadow; rest the pointer on it 3 s for a ← that moves you left.")
            add(MenuBarManager.ticked(Self.virtualDesktopAutoTitle, mirror.autoStart),
                icon: MenuBarManager.emojiIcon("🪞"), action: #selector(toggleVirtualDesktopAutoAction),
                tip: "Switch 🪞 Virtual Desktop on by itself when Zoom or Teams starts. It still goes off when the last of them quits.")
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
            tip: "While Zoom or Teams shares, the Retina runs at its Default resolution, 1728 × 1117 (sharp, 2×). The mode it had before comes back when the share ends.")
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
    /// Victor Mirror answers with its new state; the tick follows that, not the click.
    @objc private func toggleVirtualDesktopAction() {
        MirrorProxy.virtualDesktop("/virtual-desktop/set?on=\((mirror?.up ?? false) ? 0 : 1)") { [weak self] in
            self?.mirror = $0; self?.apply()
        }
    }
    @objc private func toggleVirtualDesktopAutoAction() {
        MirrorProxy.virtualDesktop("/virtual-desktop/auto?on=\((mirror?.autoStart ?? true) ? 0 : 1)") { [weak self] in
            self?.mirror = $0; self?.apply()
        }
    }

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
    /// Acts on the tick, like 🎞️: a switched Retina is given back now.
    @objc private func toggleRetinaShareResAction() {
        RetinaShareResolutionSettings.isEnabled.toggle()
        onToggleRetinaShareRes?()
    }

    static let virtualDesktopTitle = "Virtual Desktop"
    static let virtualDesktopAutoTitle = "Auto-start on Zoom/Teams"
    static let faceoverTitle = "Auto Share Faceover"
    static let retinaCapTitle = "Retina 60 Hz in Zoom/Teams"
    static let retinaShareResTitle = "Retina 1728×1117 while sharing"
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
