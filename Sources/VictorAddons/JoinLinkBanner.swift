import AppKit
import CoreImage
import Foundation

/// Banner that displays participant join URL at top of screen.
/// A link never expires on its own: it stays up until the red ✕ in the
/// bottom-right corner is clicked (or its menu row is clicked again).
/// A click on the QR blows it up to fill the screen under the link, for the back
/// of the room; a second click sends it back to its corner.
/// A click on the link itself shrinks it into the middle of the menu bar — no QR,
/// no ✕, clear of the status icons on the right — and a click there brings it
/// back large. Every show starts large.
class JoinLinkBanner: NSPanel {
    private let urlLabel: NSTextField
    private let clickView = BannerClickView()
    private var bannerShowing: Bool = false
    private(set) var isCompact = false
    private var shownUrl = ""
    private var shownUppercase = false
    /// While compact: re-fits the pill when a status icon comes or goes.
    private var compactRefit: Timer?
    /// While compact: when the pill starts fading to `fadedAlpha`.
    private var fadeTimer: Timer?
    private var fadeDeadline = Date.distantFuture

    // The pill fades after 10 min in the bar; a hover brings it back for 5 more.
    // Both can be shortened for a test: `defaults write ro.victorrentea.macos-addons
    // JoinLinkFadeAfter 5` / `JoinLinkFadeAfterHover 3` (seconds).
    private static var fadeAfter: TimeInterval { delay("JoinLinkFadeAfter", or: 10 * 60) }
    private static var fadeAfterHover: TimeInterval { delay("JoinLinkFadeAfterHover", or: 5 * 60) }
    static let fadedAlpha: CGFloat = 0.2
    static let fadeDuration: TimeInterval = 20

    private static func delay(_ key: String, or fallback: TimeInterval) -> TimeInterval {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : fallback
    }
    /// The session's Interact link, as opposed to a clipboard link — which of
    /// the two menu rows carries the ✓.
    private(set) var isSessionLink = false

    /// The display the banner belongs on, by id: an `NSScreen` kept across a
    /// sleep or a display change goes stale — after the 25 Nov wake it still said
    /// 1920 pt wide on a 1728 pt panel, so the link overflowed the right edge, the
    /// QR hung off the corner and the compact pill landed under the menu bar.
    private var targetDisplayID: CGDirectDisplayID?
    private var targetScreen: NSScreen {
        NSScreen.screens.first { Self.displayID(of: $0) == targetDisplayID } ?? AppDelegate.findRetinaScreen()
    }
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
    private var relayoutWork: DispatchWorkItem?
    // The link fills the screen edge to edge: the font is scaled up (or down)
    // until the text spans the width minus this gutter, and the banner's
    // height follows the text.
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 14

    // QR code panel
    private var qrPanel: NSPanel?
    private var qrImageView: NSImageView?
    private(set) var isQRExpanded = false
    static let qrMargin: CGFloat = 20

    /// Where the QR goes: the bottom-right corner, or — expanded — the largest
    /// square that fits between the bottom of the screen and the link banner.
    static func qrFrame(screen: NSRect, banner: NSRect, expanded: Bool) -> NSRect {
        guard expanded else {
            let size = screen.height * 0.30
            return NSRect(x: screen.maxX - size - qrMargin, y: screen.minY + qrMargin, width: size, height: size)
        }
        let room = banner.minY - screen.minY
        let size = max(0, min(screen.width, room) - qrMargin * 2)
        return NSRect(x: screen.midX - size / 2, y: screen.minY + (room - size) / 2, width: size, height: size)
    }

    // The red ✕. Its own panel because the banner itself is click-through.
    private var closePanel: BannerClosePanel?

    init(screen: NSScreen) {
        self.targetDisplayID = Self.displayID(of: screen)

        urlLabel = NSTextField(frame: .zero)

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        // A click on the link flips large ⇄ compact (the strip hides what is
        // under it anyway, behind 70 % black).
        clickView.wantsLayer = true
        clickView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        clickView.onClick = { [weak self] in self?.toggleCompact() }
        clickView.onHover = { [weak self] in self?.compactHovered() }
        self.contentView = clickView

        urlLabel.isBordered = false
        urlLabel.isEditable = false
        urlLabel.isSelectable = false
        urlLabel.drawsBackground = false
        urlLabel.alignment = .center
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.allowsEditingTextAttributes = true

        clickView.addSubview(urlLabel)

        setupQRPanel()
        setupClosePanel()

        // A wake, a resolution change or a monitor coming or going: re-fit to the
        // screen as it is now. Debounced — a wake fires several changes in a row.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.scheduleRelayout() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.scheduleRelayout() }
    }

    private func scheduleRelayout() {
        relayoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.relayout() }
        relayoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Lays the visible banner out again on its screen's current geometry.
    func relayout() {
        guard bannerShowing, !isZooming else { return }
        if isCompact {
            layoutCompact()
        } else {
            layoutLarge()
            qrPanel?.setFrame(Self.qrFrame(screen: targetScreen.frame, banner: frame, expanded: isQRExpanded), display: true)
            closePanel?.setFrame(BannerClosePanel.frame(inBanner: frame), display: true)
        }
    }

    private func setupClosePanel() {
        let panel = BannerClosePanel()
        panel.onClick = { [weak self] in self?.hide() }
        closePanel = panel
    }

    // MARK: - QR Panel setup

    private func setupQRPanel() {
        let qrSize = targetScreen.frame.height * 0.30
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.alphaValue = 1.0

        // The QR is the one clickable part besides the ✕: a click toggles its size.
        let clickView = QRClickView(frame: NSRect(x: 0, y: 0, width: qrSize, height: qrSize))
        clickView.onClick = { [weak self] in self?.toggleQRSize() }
        panel.contentView = clickView

        let imageView = NSImageView(frame: clickView.bounds)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        clickView.addSubview(imageView)

        panel.setFrame(Self.qrFrame(screen: targetScreen.frame, banner: .zero, expanded: false), display: false)

        self.qrPanel = panel
        self.qrImageView = imageView
    }

    // MARK: - Public API

    /// Re-target this banner onto a different screen. Call before show()
    /// so the banner and its QR land on the desired display.
    func setTargetScreen(_ screen: NSScreen) {
        self.targetDisplayID = Self.displayID(of: screen)
    }

    /// - Parameter uppercaseLastSegment: display the trailing path segment in caps.
    ///   True for the session join link (participants type the id in caps and the
    ///   backend matches case-insensitively); false for arbitrary clipboard URLs,
    ///   whose paths are case-sensitive and must be shown verbatim.
    /// - Parameter sessionLink: this is the session's Interact link, not a clipboard link.
    func show(url: String, uppercaseLastSegment: Bool = false, sessionLink: Bool = false) {
        shownUrl = url.trimmingCharacters(in: .whitespaces)
        shownUppercase = uppercaseLastSegment
        isCompact = false
        stopCompactRefit()
        stopFade()
        layoutLarge()

        self.alphaValue = 1.0
        self.orderFrontRegardless()
        bannerShowing = true
        isSessionLink = sessionLink

        // Every show starts with the QR small, in its corner.
        isQRExpanded = false
        showQR(for: shownUrl)
        showClose()
    }

    /// Large ⇄ compact over the menu bar: the link zooms from one into the other.
    func toggleCompact() {
        guard bannerShowing, !isZooming else { return }
        let snapshot = labelSnapshot()
        isCompact.toggle()
        let target: (frame: NSRect, fontSize: CGFloat)
        if isCompact {
            hideQR(keepExpansion: true)
            closePanel?.orderOut(nil)
            target = compactGeometry()
        } else {
            stopCompactRefit()
            stopFade()
            target = largeGeometry()
        }
        zoom(snapshot: snapshot, to: target) { [weak self] in
            guard let self, self.bannerShowing else { return }
            if self.isCompact {
                self.layoutCompact()
                self.startCompactRefit()
                self.scheduleFade(after: Self.fadeAfter)
            } else {
                self.layoutLarge()
                self.showQR(for: self.shownUrl)
                self.showClose()
            }
        }
    }

    private var isZooming = false
    static let zoomDuration: TimeInterval = 0.35

    /// The text as a picture, so it can scale smoothly while the panel resizes.
    private func labelSnapshot() -> NSImage? {
        guard let rep = urlLabel.bitmapImageRepForCachingDisplay(in: urlLabel.bounds) else { return nil }
        urlLabel.cacheDisplay(in: urlLabel.bounds, to: rep)
        let image = NSImage(size: urlLabel.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Panel and text glide to `target` together; the real label comes back at the end.
    private func zoom(snapshot: NSImage?, to target: (frame: NSRect, fontSize: CGFloat), then done: @escaping () -> Void) {
        guard let snapshot else { done(); return }
        let textSize = buildAttributedString(url: shownUrl, fontSize: target.fontSize, uppercaseLastSegment: shownUppercase).size()
        let w = ceil(textSize.width) + 4, h = ceil(textSize.height)
        let textTarget = NSRect(x: (target.frame.width - w) / 2, y: (target.frame.height - h) / 2, width: w, height: h)

        let picture = NSImageView(frame: urlLabel.frame)
        picture.image = snapshot
        picture.imageScaling = .scaleAxesIndependently
        clickView.addSubview(picture)
        urlLabel.isHidden = true
        if isCompact { clickView.layer?.cornerRadius = 6 }
        isZooming = true

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.zoomDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(target.frame, display: true)
            picture.animator().frame = textTarget
        }, completionHandler: { [weak self] in
            picture.removeFromSuperview()
            self?.urlLabel.isHidden = false
            self?.isZooming = false
            done()
        })
    }

    private func showClose() {
        // After the banner, so the ✕ sits on top of it.
        closePanel?.setFrame(BannerClosePanel.frame(inBanner: frame), display: false)
        closePanel?.alphaValue = 1.0
        closePanel?.orderFrontRegardless()
    }

    /// The link edge to edge across the screen, right under the menu bar.
    private func largeGeometry() -> (frame: NSRect, fontSize: CGFloat) {
        let screenWidth = targetScreen.frame.width
        let maxWidth = screenWidth - horizontalPadding * 2
        // A short clipboard URL would otherwise grow to half the screen.
        let maxFontSize = floor(targetScreen.frame.height * 0.15)

        // Monospaced text scales linearly with the font, so one measurement at a
        // reference size gives the size that spans exactly `maxWidth`.
        let measured = textWidth(atFontSize: Self.referenceFontSize)
        let fontSize = measured > 0
            ? min(maxFontSize, max(24, floor(Self.referenceFontSize * maxWidth / measured)))
            : 76
        let textHeight = ceil(buildAttributedString(url: shownUrl, fontSize: fontSize, uppercaseLastSegment: shownUppercase).size().height)
        let bannerHeight = textHeight + verticalPadding * 2
        let bannerY = targetScreen.frame.maxY - Self.menuBarHeight(of: targetScreen) - bannerHeight
        return (NSRect(x: targetScreen.frame.minX, y: bannerY, width: screenWidth, height: bannerHeight), fontSize)
    }

    /// A pill in the middle of the menu bar, left of the status icons. Under the
    /// notch on the laptop's own panel, but whole on a projector or a share.
    private func compactGeometry() -> (frame: NSRect, fontSize: CGFloat) {
        let bar = Self.menuBarHeight(of: targetScreen)
        return Self.compactLayout(
            screen: targetScreen.frame,
            barHeight: bar,
            statusItemsMinX: Self.statusItemsMinX(on: targetScreen, barHeight: bar),
            widthPerPoint: textWidth(atFontSize: Self.referenceFontSize) / Self.referenceFontSize)
    }

    private func layoutLarge() { apply(largeGeometry(), cornerRadius: 0) }
    private func layoutCompact() { apply(compactGeometry(), cornerRadius: 6) }

    /// The label at that size, centred in the panel at that frame.
    private func apply(_ geometry: (frame: NSRect, fontSize: CGFloat), cornerRadius: CGFloat) {
        urlLabel.attributedStringValue = buildAttributedString(url: shownUrl, fontSize: geometry.fontSize, uppercaseLastSegment: shownUppercase)
        urlLabel.sizeToFit()
        let textW = min(ceil(urlLabel.frame.width), geometry.frame.width), textH = ceil(urlLabel.frame.height)
        if frame != geometry.frame { setFrame(geometry.frame, display: true) }
        clickView.layer?.cornerRadius = cornerRadius
        urlLabel.frame = NSRect(x: (geometry.frame.width - textW) / 2, y: (geometry.frame.height - textH) / 2,
                                width: textW, height: textH)
    }

    private func startCompactRefit() {
        stopCompactRefit()
        compactRefit = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.isCompact, self.bannerShowing else { return }
            self.layoutCompact()
        }
    }

    private func scheduleFade(after delay: TimeInterval) {
        fadeTimer?.invalidate()
        fadeDeadline = Date().addingTimeInterval(delay)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.isCompact, self.bannerShowing else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = Self.fadedAlpha
            }
        }
    }

    /// Back to opaque, and opaque for at least five more minutes.
    private func compactHovered() {
        guard isCompact, bannerShowing else { return }
        if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self.animator().alphaValue = 1
            }
        }
        if fadeDeadline.timeIntervalSinceNow < Self.fadeAfterHover {
            scheduleFade(after: Self.fadeAfterHover)
        }
    }

    private func stopFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeDeadline = .distantFuture
        // Cuts a running fade short too.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            self.animator().alphaValue = bannerShowing ? 1 : 0
        }
    }

    private func stopCompactRefit() {
        compactRefit?.invalidate()
        compactRefit = nil
    }

    private static let referenceFontSize: CGFloat = 100

    private func textWidth(atFontSize size: CGFloat) -> CGFloat {
        buildAttributedString(url: shownUrl, fontSize: size, uppercaseLastSegment: shownUppercase).size().width
    }

    // MARK: - Compact geometry

    static let compactGap: CGFloat = 8
    static let compactPadding: CGFloat = 10

    /// Where the compact pill goes and how big its text is. Centred on the screen;
    /// pushed left when it would reach the status icons, shrunk only when even the
    /// whole bar left of them is too narrow. `widthPerPoint` is the text width per
    /// point of font size (monospaced text scales linearly).
    static func compactLayout(screen: NSRect, barHeight: CGFloat, statusItemsMinX: CGFloat?,
                              widthPerPoint: CGFloat) -> (frame: NSRect, fontSize: CGFloat) {
        let rightLimit = (statusItemsMinX ?? screen.maxX) - compactGap
        let leftLimit = screen.minX + compactGap
        // As big as the bar allows: it has to read on a small projector.
        var fontSize = floor(barHeight * 0.8)
        var width = ceil(widthPerPoint * fontSize) + compactPadding * 2
        if width > rightLimit - leftLimit, widthPerPoint > 0 {
            fontSize = max(9, floor((rightLimit - leftLimit - compactPadding * 2) / widthPerPoint))
            width = ceil(widthPerPoint * fontSize) + compactPadding * 2
        }
        var x = screen.midX - width / 2
        if x + width > rightLimit { x = rightLimit - width }
        if x < leftLimit { x = leftLimit }
        let frame = NSRect(x: x, y: screen.maxY - barHeight, width: width, height: barHeight)
        return (frame, fontSize)
    }

    /// The menu bar's height on that screen: 24 pt classic, ~33 pt with a notch.
    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let measured = screen.frame.maxY - screen.visibleFrame.maxY
        if measured > 0 { return measured }
        // Auto-hidden menu bar: the notch still sets the band.
        return max(screen.safeAreaInsets.top, 24)
    }

    /// The left edge (Cocoa x) of the leftmost status icon on that screen's menu
    /// bar, nil if none is found. Status icons are layer-25 windows lying in the
    /// bar's band; ours are left out.
    static func statusItemsMinX(on screen: NSScreen, barHeight: CGFloat) -> CGFloat? {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Window bounds are in global display coordinates: origin top-left of the primary.
        let bandTop = primary.frame.maxY - screen.frame.maxY
        let band = CGRect(x: screen.frame.minX, y: bandTop, width: screen.frame.width, height: barHeight)
        let own = Set(NSApp.windows.compactMap { $0 is JoinLinkBanner ? $0.windowNumber : nil })
        var minX: CGFloat?
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  let number = w[kCGWindowNumber as String] as? Int, !own.contains(number),
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict),
                  b.width < screen.frame.width / 2,
                  band.contains(CGPoint(x: b.midX, y: b.midY))
            else { continue }
            minX = min(minX ?? b.minX, b.minX)
        }
        return minX
    }

    func hide() {
        self.alphaValue = 0.0
        bannerShowing = false
        isSessionLink = false
        isCompact = false
        stopCompactRefit()
        stopFade()
        self.orderOut(nil)
        hideQR()
        closePanel?.orderOut(nil)
    }

    var bannerIsVisible: Bool { bannerShowing }

    /// Where the ✕ is on screen, in Cocoa points; nil while the banner is down or compact.
    var closeButtonFrame: NSRect? { bannerShowing && !isCompact ? closePanel?.frame : nil }

    /// Where the link is on screen (the strip, or the compact pill); nil while down.
    var linkFrameOnScreen: NSRect? { bannerShowing ? frame : nil }

    // MARK: - QR code generation and display

    private func showQR(for url: String) {
        guard let qrPanel = qrPanel, let qrImageView = qrImageView else { return }

        // Re-position against the current targetScreen so multi-monitor swaps
        // and screen-config changes after launch place the QR in the right corner.
        qrPanel.setFrame(Self.qrFrame(screen: targetScreen.frame, banner: frame, expanded: isQRExpanded), display: false)

        // Prepend https:// for the QR code so phones can open it directly
        let fullUrl = url.hasPrefix("http") ? url : "https://\(url)"
        if let qrImage = generateQRCode(from: fullUrl) {
            qrImageView.image = qrImage
        }
        qrPanel.alphaValue = 1.0
        qrPanel.orderFrontRegardless()
    }

    /// `keepExpansion`: going compact remembers the QR's size for the way back.
    private func hideQR(keepExpansion: Bool = false) {
        qrPanel?.alphaValue = 0.0
        qrPanel?.orderOut(nil)
        if !keepExpansion { isQRExpanded = false }
    }

    /// Corner ⇄ full screen under the link.
    func toggleQRSize() {
        guard bannerShowing, !isCompact, let qrPanel = qrPanel else { return }
        isQRExpanded.toggle()
        let target = Self.qrFrame(screen: targetScreen.frame, banner: frame, expanded: isQRExpanded)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            qrPanel.animator().setFrame(target, display: true)
        }
    }

    /// Where the QR is on screen, in Cocoa points; nil while the banner is down or compact.
    var qrFrameOnScreen: NSRect? { bannerShowing && !isCompact ? qrPanel?.frame : nil }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up the QR code (it's tiny by default)
        let scale = 20.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = ciImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    // MARK: - Attributed string

    private func buildAttributedString(url: String, fontSize: CGFloat = 76, uppercaseLastSegment: Bool = false) -> NSAttributedString {
        let parts = url.split(separator: "/")
        let result = NSMutableAttributedString()
        if parts.count > 1 {
            let domainPart = parts.dropLast().joined(separator: "/")
            result.append(NSAttributedString(
                string: domainPart + "/",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            ))
            // Only the display changes — the QR code and the clipboard still carry
            // the original URL.
            let tail = String(parts.last!)
            result.append(NSAttributedString(
                string: uppercaseLastSegment ? tail.uppercased() : tail,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: NSColor.yellow
                ]
            ))
        } else {
            result.append(NSAttributedString(
                string: url,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            ))
        }
        return result
    }
}

/// The red ✕ in the banner's bottom-right corner. A panel of its own, because the
/// banner is click-through on purpose: the room's screen stays usable under it.
final class BannerClosePanel: NSPanel {
    static let size: CGFloat = 30
    static let inset: CGFloat = 6

    var onClick: (() -> Void)?

    static func frame(inBanner banner: NSRect) -> NSRect {
        NSRect(x: banner.maxX - size - inset, y: banner.minY + inset, width: size, height: size)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        let button = BannerCloseButton(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        button.onClick = { [weak self] in self?.onClick?() }
        contentView = button
    }
}

/// Hosts the link label and turns a click anywhere on the strip (or pill) into `onClick`.
private final class BannerClickView: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The label would otherwise swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Hosts the QR image and turns a click on it into `onClick`.
private final class QRClickView: NSView {
    var onClick: (() -> Void)?

    // The panel never becomes key, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The image view would otherwise swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    // Overridden so that the matching mouseUp comes here.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

private final class BannerCloseButton: NSView {
    var onClick: (() -> Void)?

    // Takes the first click: the panel never becomes key, so without this the
    // click would only ever activate it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let arm = bounds.insetBy(dx: bounds.width * 0.32, dy: bounds.height * 0.32)
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: arm.minX, y: arm.minY))
        cross.line(to: NSPoint(x: arm.maxX, y: arm.maxY))
        cross.move(to: NSPoint(x: arm.minX, y: arm.maxY))
        cross.line(to: NSPoint(x: arm.maxX, y: arm.minY))
        cross.lineWidth = 3
        cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }

    // Overridden so that the matching mouseUp comes here.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
