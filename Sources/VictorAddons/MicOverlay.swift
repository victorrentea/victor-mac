import AppKit

/// What the 🎙️ menu-bar item draws **beside** the microphone for the power state
/// (2026-11-20; beside, not over it, since 2026-11-25 — Victor: *"pune linia
/// roșie lângă microfon, nu peste microfon"*: across the drawing it hid which mic
/// it was). On AC and transcribing there is nothing: the icon stays 18 pt wide.
///
/// - `zigzag`: on battery, the mics go to disk but nothing is transcribed — a red
///   vertical zig-zag in its own column right of the microphone.
/// - `pause`: on battery, not recording — listening for voice, or switched off
///   from the menu — two thick green vertical bars, the "pause" sign, same column.
///
/// Each mark is stroked over a halo in the bar's opposite ink, so it stays readable
/// on any wallpaper behind a translucent bar.
enum MicOverlay: Equatable {
    case none
    case zigzag
    case pause

    /// The microphone's own square.
    static let micSide: CGFloat = 18
    /// The column the mark gets, right of the microphone.
    static let column: CGFloat = 6

    /// The whole icon: the mic's square, plus the column when there is a mark.
    static func canvas(_ overlay: MicOverlay) -> NSSize {
        NSSize(width: micSide + (overlay == .none ? 0 : column), height: micSide)
    }

    /// Draws the mark into the current focus, in the column right of the mic.
    static func draw(_ overlay: MicOverlay, dark: Bool) {
        let halo: NSColor = dark ? NSColor.black.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.9)
        let x0 = micSide, h = micSide
        switch overlay {
        case .none:
            return
        case .zigzag:
            // Five teeth top to bottom, swinging across the column.
            let teeth = 6
            let points: [NSPoint] = (0...teeth).map { i in
                NSPoint(x: x0 + (i.isMultiple(of: 2) ? 1.5 : column - 1.5),
                        y: 1.5 + (h - 3) * CGFloat(teeth - i) / CGFloat(teeth))
            }
            let path = NSBezierPath()
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
            let barW: CGFloat = 2, barH: CGFloat = 10, gap: CGFloat = 1.5
            let bx = x0 + (column - (2 * barW + gap)) / 2, by = (h - barH) / 2
            let bars = [NSRect(x: bx, y: by, width: barW, height: barH),
                        NSRect(x: bx + barW + gap, y: by, width: barW, height: barH)]
            halo.setFill()
            NSBezierPath(roundedRect: NSRect(x: bx - 0.5, y: by - 0.5, width: 2 * barW + gap + 1, height: barH + 1),
                         xRadius: 1, yRadius: 1).fill()
            NSColor.systemGreen.setFill()
            bars.forEach { NSBezierPath(roundedRect: $0, xRadius: 0.6, yRadius: 0.6).fill() }
        }
    }
}
