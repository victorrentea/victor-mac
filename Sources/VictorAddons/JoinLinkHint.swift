import AppKit
import CoreText
import QuartzCore

/// "enter this in your browser", hand-written under the large session link, with
/// an arrow curving up to it. White with a black outline, so it reads over any
/// wallpaper; every letter wobbles on its own and the arrow nudges up at the link,
/// so the room's eye goes there. Click-through: the screen under it stays usable.
/// Only while the link is large — the menu-bar pill and the blown-up QR hide it.
final class JoinLinkHint: NSPanel {
    static let text = "enter this in your browser"

    /// Chalkduster is the hand in the original sketch, and ships with macOS.
    static func font(ofSize size: CGFloat) -> NSFont {
        NSFont(name: "Chalkduster", size: size)
            ?? NSFont(name: "MarkerFelt-Wide", size: size)
            ?? .boldSystemFont(ofSize: size)
    }

    /// How far the line of text climbs to the right, as in the sketch.
    static let tilt: CGFloat = 6 * .pi / 180
    /// The text spans this much of the screen's width…
    static let widthFraction: CGFloat = 0.42
    /// …unless that would make it taller than this much of the screen's height.
    static let maxFontFraction: CGFloat = 0.07

    /// Where every part goes, in the panel's own coordinates (y up), for a font size.
    struct Geometry: Equatable {
        var size: NSSize
        var fontSize: CGFloat
        /// The text line's left end, on the line's bottom edge; the line climbs `tilt` from there.
        var textOrigin: CGPoint
        var lineWidth: CGFloat
        var lineHeight: CGFloat
        /// The arrow leaves the end of the text and ends, tip up, at the panel's top.
        var arrowStart: CGPoint
        var arrowTip: CGPoint
    }

    static func geometry(fontSize fs: CGFloat, widthPerPoint: CGFloat) -> Geometry {
        let pad = fs * 0.3
        let lineWidth = widthPerPoint * fs
        let lineHeight = fs * 1.4
        let origin = CGPoint(x: pad, y: pad)
        // The end of the text, half a line up, carried along the tilt.
        let along = lineWidth + fs * 0.25, up = lineHeight * 0.5
        let start = CGPoint(x: origin.x + along * cos(tilt) - up * sin(tilt),
                            y: origin.y + along * sin(tilt) + up * cos(tilt))
        let tip = CGPoint(x: start.x + fs * 1.0, y: start.y + fs * 1.6)
        let size = NSSize(width: ceil(tip.x + fs * 0.6 + pad), height: ceil(tip.y + pad))
        return Geometry(size: size, fontSize: fs, textOrigin: origin, lineWidth: lineWidth,
                        lineHeight: lineHeight, arrowStart: start, arrowTip: tip)
    }

    /// The panel on screen: centred, its arrow tip just under the link.
    static func layout(screen: NSRect, banner: NSRect, widthPerPoint: CGFloat) -> (frame: NSRect, geometry: Geometry) {
        let fs = max(18, floor(min(screen.width * widthFraction / max(widthPerPoint, 1),
                                   screen.height * maxFontFraction)))
        let g = geometry(fontSize: fs, widthPerPoint: widthPerPoint)
        let gap = fs * 0.1
        let frame = NSRect(x: round(screen.midX - g.size.width / 2), y: round(banner.minY - gap - g.size.height),
                           width: g.size.width, height: g.size.height)
        return (frame, g)
    }

    /// Text width per point of font size, measured once.
    static let widthPerPoint: CGFloat = {
        let ref: CGFloat = 100
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font(ofSize: ref)]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) / ref
    }()

    private var builtFor: (fontSize: CGFloat, scale: CGFloat)?
    private(set) var isShowing = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        contentView = view
    }

    func show(under banner: NSRect, on screen: NSScreen) {
        let (frame, g) = Self.layout(screen: screen.frame, banner: banner, widthPerPoint: Self.widthPerPoint)
        setFrame(frame, display: false)
        let scale = screen.backingScaleFactor
        if builtFor?.fontSize != g.fontSize || builtFor?.scale != scale || !isShowing {
            build(g, scale: scale)
            builtFor = (g.fontSize, scale)
        }
        if !isShowing {
            alphaValue = 1
            orderFrontRegardless()
            isShowing = true
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        orderOut(nil)
        contentView?.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        builtFor = nil
    }

    // MARK: - Drawing

    private func build(_ g: Geometry, scale: CGFloat) {
        guard let root = contentView?.layer else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let font = Self.font(ofSize: g.fontSize)
        let outline = g.fontSize * 0.16

        // The line of text, tilted around its left end.
        let line = CALayer()
        line.anchorPoint = .zero
        line.bounds = CGRect(x: 0, y: 0, width: g.lineWidth, height: g.lineHeight)
        line.position = g.textOrigin
        line.transform = CATransform3DMakeRotation(Self.tilt, 0, 0, 1)
        root.addSublayer(line)

        let full = CTLineCreateWithAttributedString(NSAttributedString(string: Self.text, attributes: [.font: font]))
        let descent = font.descender.magnitude
        let baseline = (g.lineHeight - (font.ascender + descent)) / 2 + descent
        let now = CACurrentMediaTime()
        for (i, ch) in Self.text.enumerated() where ch != " " {
            let x = CTLineGetOffsetForStringIndex(full, i, nil)
            let next = CTLineGetOffsetForStringIndex(full, i + 1, nil)
            let w = next - x + outline * 2
            let layer = CALayer()
            layer.contentsScale = scale
            layer.contents = Self.glyphImage(String(ch), font: font, size: CGSize(width: w, height: g.lineHeight),
                                             baseline: baseline, outline: outline, scale: scale)
            layer.frame = CGRect(x: x - outline, y: 0, width: w, height: g.lineHeight)
            line.addSublayer(layer)
            Self.wobble(layer, fontSize: g.fontSize, startingAt: now)
        }

        // The arrow: a black stroke under a thinner white one, so it has the same outline.
        let arrow = CALayer()
        arrow.frame = root.bounds
        for (color, width) in [(NSColor.black, g.fontSize * 0.3), (NSColor.white, g.fontSize * 0.16)] {
            let shape = CAShapeLayer()
            shape.contentsScale = scale
            shape.path = Self.arrowPath(g)
            shape.strokeColor = color.cgColor
            shape.fillColor = nil
            shape.lineWidth = width
            shape.lineCap = .round
            shape.lineJoin = .round
            arrow.addSublayer(shape)
        }
        root.addSublayer(arrow)
        let nudge = CABasicAnimation(keyPath: "transform.translation.y")
        nudge.fromValue = -g.fontSize * 0.12
        nudge.toValue = 0
        nudge.duration = 0.55
        nudge.autoreverses = true
        nudge.repeatCount = .infinity
        nudge.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arrow.add(nudge, forKey: "nudge")
    }

    /// A hand-drawn arc from the end of the text up to the link, with an open head.
    static func arrowPath(_ g: Geometry) -> CGPath {
        let s = g.arrowStart, t = g.arrowTip, fs = g.fontSize
        let c1 = CGPoint(x: s.x + fs * 0.75, y: s.y + fs * 0.05)
        let c2 = CGPoint(x: t.x + fs * 0.05, y: t.y - fs * 0.9)
        let path = CGMutablePath()
        path.move(to: s)
        path.addCurve(to: t, control1: c1, control2: c2)
        // The head opens back along the direction the arc arrives from.
        let back = atan2(c2.y - t.y, c2.x - t.x)
        let wing = fs * 0.5, spread: CGFloat = 0.6
        for side in [-spread, spread] {
            path.move(to: t)
            path.addLine(to: CGPoint(x: t.x + wing * cos(back + side), y: t.y + wing * sin(back + side)))
        }
        return path
    }

    /// One letter: a fat round-joined black stroke, then the white letter over it.
    private static func glyphImage(_ s: String, font: NSFont, size: CGSize, baseline: CGFloat,
                                   outline: CGFloat, scale: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let key = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, key: true]))
        let at = CGPoint(x: outline, y: baseline)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        ctx.setTextDrawingMode(.stroke)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(outline)
        ctx.textPosition = at
        CTLineDraw(line, ctx)

        // A thin white stroke with the fill closes the chalk's speckles.
        ctx.setTextDrawingMode(.fillStroke)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(outline * 0.2)
        ctx.textPosition = at
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    /// Each letter rocks and bobs a little, on its own beat, so the line never sits still.
    private static func wobble(_ layer: CALayer, fontSize: CGFloat, startingAt now: CFTimeInterval) {
        let angle = CGFloat.random(in: 3...6) * .pi / 180 * (Bool.random() ? 1 : -1)
        let rock = CABasicAnimation(keyPath: "transform.rotation.z")
        rock.fromValue = -angle
        rock.toValue = angle
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        let lift = fontSize * CGFloat.random(in: 0.03...0.07)
        bob.fromValue = -lift
        bob.toValue = lift
        for (anim, key) in [(rock, "rock"), (bob, "bob")] {
            anim.duration = Double.random(in: 0.35...0.7)
            anim.beginTime = now + Double.random(in: 0...0.7)
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: key)
        }
    }
}
