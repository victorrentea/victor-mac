import AppKit
import CoreImage
import Foundation

/// Banner that displays participant join URL at top of screen.
/// A link never expires on its own: it stays up until the red ✕ in the
/// bottom-right corner is clicked (or its menu row is clicked again).
/// A click on the QR blows it up to fill the screen under the link, for the back
/// of the room; a second click sends it back to its corner.
class JoinLinkBanner: NSPanel {
    private let urlLabel: NSTextField
    private var bannerShowing: Bool = false
    /// The session's Interact link, as opposed to a clipboard link — which of
    /// the two menu rows carries the ✓.
    private(set) var isSessionLink = false

    private var targetScreen: NSScreen
    private let menuBarHeight: CGFloat = 25
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
        self.targetScreen = screen

        urlLabel = NSTextField(frame: .zero)

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true  // clicks pass through; we poll for hover

        urlLabel.isBordered = false
        urlLabel.isEditable = false
        urlLabel.isSelectable = false
        urlLabel.drawsBackground = false
        urlLabel.alignment = .center
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.allowsEditingTextAttributes = true

        self.contentView?.addSubview(urlLabel)

        setupQRPanel()
        setupClosePanel()
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
        self.targetScreen = screen
    }

    /// - Parameter uppercaseLastSegment: display the trailing path segment in caps.
    ///   True for the session join link (participants type the id in caps and the
    ///   backend matches case-insensitively); false for arbitrary clipboard URLs,
    ///   whose paths are case-sensitive and must be shown verbatim.
    /// - Parameter sessionLink: this is the session's Interact link, not a clipboard link.
    func show(url: String, uppercaseLastSegment: Bool = false, sessionLink: Bool = false) {
        let trimmedUrl = url.trimmingCharacters(in: .whitespaces)
        let screenWidth = targetScreen.frame.width
        let maxWidth = screenWidth - horizontalPadding * 2
        // A short clipboard URL would otherwise grow to half the screen.
        let maxFontSize = floor(targetScreen.frame.height * 0.15)

        // Monospaced text scales linearly with the font, so one measurement at a
        // reference size gives the size that spans exactly `maxWidth`.
        let referenceSize: CGFloat = 100
        let measured = buildAttributedString(url: trimmedUrl, fontSize: referenceSize, uppercaseLastSegment: uppercaseLastSegment).size().width
        let fontSize = measured > 0
            ? min(maxFontSize, max(24, floor(referenceSize * maxWidth / measured)))
            : 76
        urlLabel.attributedStringValue = buildAttributedString(url: trimmedUrl, fontSize: fontSize, uppercaseLastSegment: uppercaseLastSegment)
        urlLabel.sizeToFit()

        let fittedWidth = min(ceil(urlLabel.frame.width), screenWidth)
        let textHeight = ceil(urlLabel.frame.height)
        let bannerHeight = textHeight + verticalPadding * 2
        let bannerX = targetScreen.frame.origin.x
        let bannerY = targetScreen.frame.origin.y + targetScreen.frame.height - menuBarHeight - bannerHeight

        let frame = NSRect(x: bannerX, y: bannerY, width: screenWidth, height: bannerHeight)
        self.setFrame(frame, display: false)

        urlLabel.frame = NSRect(x: (screenWidth - fittedWidth) / 2, y: verticalPadding, width: fittedWidth, height: textHeight)

        self.alphaValue = 1.0
        self.orderFrontRegardless()
        bannerShowing = true
        isSessionLink = sessionLink

        // Show QR code
        showQR(for: trimmedUrl)

        // After the banner, so the ✕ sits on top of it.
        closePanel?.setFrame(BannerClosePanel.frame(inBanner: frame), display: false)
        closePanel?.alphaValue = 1.0
        closePanel?.orderFrontRegardless()
    }

    func hide() {
        self.alphaValue = 0.0
        bannerShowing = false
        isSessionLink = false
        self.orderOut(nil)
        hideQR()
        closePanel?.orderOut(nil)
    }

    var bannerIsVisible: Bool { bannerShowing }

    /// Where the ✕ is on screen, in Cocoa points; nil while the banner is down.
    var closeButtonFrame: NSRect? { bannerShowing ? closePanel?.frame : nil }

    // MARK: - QR code generation and display

    private func showQR(for url: String) {
        guard let qrPanel = qrPanel, let qrImageView = qrImageView else { return }

        // Re-position against the current targetScreen so multi-monitor swaps
        // and screen-config changes after launch place the QR in the right corner.
        // Every show starts small, in the corner.
        isQRExpanded = false
        qrPanel.setFrame(Self.qrFrame(screen: targetScreen.frame, banner: frame, expanded: false), display: false)

        // Prepend https:// for the QR code so phones can open it directly
        let fullUrl = url.hasPrefix("http") ? url : "https://\(url)"
        if let qrImage = generateQRCode(from: fullUrl) {
            qrImageView.image = qrImage
        }
        qrPanel.alphaValue = 1.0
        qrPanel.orderFrontRegardless()
    }

    private func hideQR() {
        qrPanel?.alphaValue = 0.0
        qrPanel?.orderOut(nil)
        isQRExpanded = false
    }

    /// Corner ⇄ full screen under the link.
    func toggleQRSize() {
        guard bannerShowing, let qrPanel = qrPanel else { return }
        isQRExpanded.toggle()
        let target = Self.qrFrame(screen: targetScreen.frame, banner: frame, expanded: isQRExpanded)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            qrPanel.animator().setFrame(target, display: true)
        }
    }

    /// Where the QR is on screen, in Cocoa points; nil while the banner is down.
    var qrFrameOnScreen: NSRect? { bannerShowing ? qrPanel?.frame : nil }

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
