import AppKit

/// ☕ **The big hover card under the `☕ 9:42` countdown** (2026-11-27, Victor:
/// *"hovering the menu bar icon should show a larger tooltip and clearly state
/// that additional coffees make the break come one minute earlier"*).
///
/// The native `toolTip` is small grey system text, unreadable on a projector and
/// easy to miss — and this is the one place the room learns that its ☕ count.
/// So the slot gets its own card: a dark rounded panel just under the menu bar,
/// big type, shown after a short rest on the slot and hidden the moment the
/// pointer leaves or the slot's menu opens.
///
/// Polled, not a tracking area: the poll only runs while the countdown owns the
/// slot (minutes a day), and it is also what notices the menu opening (the
/// button highlights) — a tracking area would miss that exit.
final class UntilBreakHoverTip {
    private static let pollSeconds: TimeInterval = 0.1
    private static let restSeconds: TimeInterval = 0.25

    /// The slot's button, sampled every poll (the status item can be recreated).
    var button: () -> NSStatusBarButton?
    private var poll: Timer?
    private var hoverSince: Date?
    private var panel: NSPanel?
    private let headline = NSTextField(labelWithString: "")
    private let rule = NSTextField(labelWithString: "")
    private var remainingText = ""

    init(button: @escaping () -> NSStatusBarButton?) {
        self.button = button
    }

    /// Countdown on (non-nil, e.g. `9:42`) or off (nil).
    func update(remaining: String?) {
        guard let remaining else { stop(); return }
        remainingText = remaining
        headline.stringValue = "☕ Break in \(remaining)"
        if poll == nil {
            let t = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            poll = t
        }
    }

    private func stop() {
        poll?.invalidate(); poll = nil
        hoverSince = nil
        hide()
    }

    /// Shown regardless of the pointer until then (`/test/break/until/tip`).
    private var pinnedUntil: Date?

    func pin(seconds: TimeInterval) -> Bool {
        guard poll != nil, let win = button()?.window else { return false }
        pinnedUntil = Date().addingTimeInterval(seconds)
        if panel == nil { show(under: win.frame, screen: win.screen) }
        return true
    }

    private func tick() {
        if let until = pinnedUntil {
            if until > Date() { return }
            pinnedUntil = nil
        }
        guard let button = button(), let win = button.window, !button.isHighlighted,
              let hit = MenuBarSlot.hovered(win.frame, at: NSEvent.mouseLocation)
        else { hoverSince = nil; hide(); return }
        if hoverSince == nil { hoverSince = Date() }
        if panel == nil, Date().timeIntervalSince(hoverSince!) >= Self.restSeconds {
            show(under: hit.rect, screen: hit.screen)
        }
    }

    private func show(under slot: NSRect, screen: NSScreen?) {
        let p = makePanel()
        headline.stringValue = "☕ Break in \(remainingText)"
        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? NSSize(width: 420, height: 110)
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? slot
        var x = slot.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = slot.minY - 8 - size.height
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
        panel = p
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
        box.layer?.cornerRadius = 14
        box.layer?.borderWidth = 1.5
        box.layer?.borderColor = NSColor.systemOrange.cgColor

        headline.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        headline.textColor = .systemOrange
        rule.stringValue = "Every extra ☕ brings the break\n1 minute earlier  (−1 min)"
        rule.font = .systemFont(ofSize: 22, weight: .semibold)
        rule.textColor = .white
        rule.maximumNumberOfLines = 2

        let stack = NSStackView(views: [headline, rule])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        p.contentView = box
        return p
    }
}

/// Where a status item shows on each screen. Its window lives on the menu bar
/// of the main display; every other screen's menu bar draws a copy at the same
/// distance from the right edge, vertically centred in that screen's own menu
/// bar (taller on the notched retina).
enum MenuBarSlot {
    static func rect(of slot: NSRect, on screen: NSScreen) -> NSRect {
        let home = NSScreen.physical.first(where: { $0.frame.contains(NSPoint(x: slot.midX, y: slot.midY)) })
        if let home, home.frame == screen.frame { return slot }
        let fromRight = (home?.frame.maxX ?? slot.maxX) - slot.maxX
        let f = screen.frame
        let barHeight = max(slot.height, f.maxY - screen.visibleFrame.maxY)
        return NSRect(x: f.maxX - fromRight - slot.width,
                      y: f.maxY - barHeight / 2 - slot.height / 2,
                      width: slot.width, height: slot.height)
    }

    /// The copy of `slot` the pointer is on, with its screen; nil when on none.
    static func hovered(_ slot: NSRect, at point: NSPoint) -> (rect: NSRect, screen: NSScreen)? {
        for screen in NSScreen.physical {
            let r = rect(of: slot, on: screen)
            // Up to the top of the screen, so the pointer pinned against the edge counts.
            let hit = NSRect(x: r.minX, y: r.minY, width: r.width, height: screen.frame.maxY - r.minY)
            if hit.contains(point) { return (r, screen) }
        }
        return nil
    }
}
