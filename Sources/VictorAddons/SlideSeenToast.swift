import Cocoa

/// 📷 + PowerPoint's icon, for a second and a half in the top-right corner of the Retina:
/// the training-assistant daemon just put a slide into the session's "slides seen" deck, the
/// PDF participants get of every slide shown, each in the last form it was on screen.
///
/// Victor asked for it (2026-11-22) to notice a capture he did not mean — a deck edited in a
/// break or at night while a session is still open. So it is small and silent, never in the
/// way of the slide: no text, nothing to click (mouse events pass through), and it only comes
/// when the seen deck changed (a slide added, or a new form of one already there: `↻`),
/// never for a slide shown again unchanged — the daemon decides that and only then sends
/// `slide_seen_captured`.
final class SlideSeenToast {
    enum Style {
        static let height: CGFloat = 40
        static let iconSize: CGFloat = 26
        static let fontSize: CGFloat = 22
        static let padding: CGFloat = 10
        static let gap: CGFloat = 4
        /// Under the menu bar, off the corner, where a slide rarely carries anything.
        static let margin: CGFloat = 12
        static let fadeIn: TimeInterval = 0.15
        static let hold: TimeInterval = 1.5
        static let fadeOut: TimeInterval = 0.4
        static let alpha: CGFloat = 0.9
    }

    /// The glyph before the icon: 📷 for a new slide, 📷↻ for a new form of one already in.
    static func glyph(updated: Bool) -> String { updated ? "📷↻" : "📷" }

    /// Top-right of `visible` (the screen's frame minus the menu bar), `margin` in from both edges.
    static func origin(size: NSSize, visible: NSRect) -> NSPoint {
        NSPoint(x: (visible.maxX - size.width - Style.margin).rounded(),
                y: (visible.maxY - size.height - Style.margin).rounded())
    }

    private var panels: [NSPanel] = []
    private var hideWork: DispatchWorkItem?
    private let screensProvider: () -> [NSScreen]

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.pillScreens }) {
        self.screensProvider = screensProvider
    }

    var isVisible: Bool { !panels.isEmpty }

    /// Show (or restart) the toast. Main thread only.
    func show(updated: Bool) {
        hideWork?.cancel()
        panels.forEach { $0.orderOut(nil) }
        panels = screensProvider().map { build(on: $0, updated: updated) }
        for panel in panels {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Style.fadeIn
                panel.animator().alphaValue = Style.alpha
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Style.fadeIn + Style.hold, execute: work)
    }

    private func fadeOut() {
        let leaving = panels
        panels = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Style.fadeOut
            leaving.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            leaving.forEach { $0.orderOut(nil) }
        })
    }

    private static func powerPointIcon() -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Powerpoint")
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: Style.iconSize, height: Style.iconSize)
        return icon
    }

    private func build(on screen: NSScreen, updated: Bool) -> NSPanel {
        let label = NSTextField(labelWithString: Self.glyph(updated: updated))
        label.font = NSFont.systemFont(ofSize: Style.fontSize)
        label.textColor = .white
        label.sizeToFit()
        let icon = Self.powerPointIcon()
        let iconWidth = icon == nil ? 0 : Style.iconSize
        let fallback: NSTextField? = icon == nil ? {
            let t = NSTextField(labelWithString: "PPT")
            t.font = NSFont.boldSystemFont(ofSize: Style.fontSize * 0.7)
            t.textColor = NSColor(calibratedRed: 0.82, green: 0.29, blue: 0.16, alpha: 1)
            t.sizeToFit()
            return t
        }() : nil
        let rightWidth = fallback?.frame.width ?? iconWidth
        let size = NSSize(width: Style.padding * 2 + label.frame.width + Style.gap + rightWidth, height: Style.height)

        let panel = NSPanel(contentRect: NSRect(origin: Self.origin(size: size, visible: screen.visibleFrame), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        content.layer?.cornerRadius = size.height / 2
        label.frame.origin = NSPoint(x: Style.padding, y: ((size.height - label.frame.height) / 2).rounded())
        content.addSubview(label)
        let rightX = Style.padding + label.frame.width + Style.gap
        if let icon {
            let view = NSImageView(frame: NSRect(x: rightX, y: ((size.height - Style.iconSize) / 2).rounded(),
                                                 width: Style.iconSize, height: Style.iconSize))
            view.image = icon
            content.addSubview(view)
        } else if let fallback {
            fallback.frame.origin = NSPoint(x: rightX, y: ((size.height - fallback.frame.height) / 2).rounded())
            content.addSubview(fallback)
        }
        panel.contentView = content
        return panel
    }
}
