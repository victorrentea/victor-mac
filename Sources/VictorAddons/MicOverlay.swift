import AppKit

/// What the 🎙️ menu-bar item draws over the microphone for the power state
/// (2026-11-20). On AC and transcribing there is nothing: a clean drawing.
///
/// - `zigzag`: on battery, the mics go to disk but nothing is transcribed — a red
///   zig-zag across the whole microphone, whichever one it is.
/// - `pause`: on battery with the recording switched off — two thick green
///   vertical bars, the "pause" sign, in the bottom-right corner.
///
/// Each mark is stroked over a halo in the bar's opposite ink, so it stays readable
/// where it crosses the white (or black) line drawing.
enum MicOverlay: Equatable {
    case none
    case zigzag
    case pause

    /// Draws into the current focus; `canvas` is the 18×18 icon.
    static func draw(_ overlay: MicOverlay, canvas: NSSize, dark: Bool) {
        let halo: NSColor = dark ? NSColor.black.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.9)
        switch overlay {
        case .none:
            return
        case .zigzag:
            let path = NSBezierPath()
            let w = canvas.width, h = canvas.height
            // Six teeth left to right across the middle of the icon: a crossing-out
            // that still lets the microphone show through.
            let teeth = 6
            let points: [NSPoint] = (0...teeth).map { i in
                NSPoint(x: 0.5 + (w - 1) * CGFloat(i) / CGFloat(teeth),
                        y: h * (i.isMultiple(of: 2) ? 0.36 : 0.64))
            }
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.lineJoinStyle = .miter
            path.lineCapStyle = .round
            halo.setStroke()
            path.lineWidth = 3.2
            path.stroke()
            NSColor.systemRed.setStroke()
            path.lineWidth = 1.7
            path.stroke()
        case .pause:
            let barW: CGFloat = 3, barH: CGFloat = 9, gap: CGFloat = 2
            let x0 = canvas.width - (2 * barW + gap) - 0.5, y0: CGFloat = 0.5
            let bars = [NSRect(x: x0, y: y0, width: barW, height: barH),
                        NSRect(x: x0 + barW + gap, y: y0, width: barW, height: barH)]
            halo.setFill()
            NSBezierPath(roundedRect: NSRect(x: x0 - 1, y: y0 - 0.5, width: 2 * barW + gap + 2, height: barH + 1),
                         xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.systemGreen.setFill()
            bars.forEach { NSBezierPath(roundedRect: $0, xRadius: 0.8, yRadius: 0.8).fill() }
        }
    }
}
