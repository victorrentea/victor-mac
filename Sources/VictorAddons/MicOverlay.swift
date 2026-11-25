import AppKit

/// What the 🎙️ menu-bar item draws **beside** the microphone for the power state
/// (2026-11-20; beside, not over it, since 2026-11-25 — Victor: *"pune linia
/// roșie lângă microfon, nu peste microfon"*: across the drawing it hid which mic
/// it was). On AC and transcribing there is nothing: the icon stays 18 pt wide.
///
/// **Two wide colour emoji since 2026-11-25** (Victor: *"semnul de pauză să fie un 🟥
/// care blink lent … acel fulger care înseamnă că sunetul se înregistrează → 🟠, tot lat
/// și el, non-blinking"*). The thin red zig-zag and the two green bars before them were
/// strokes 2 pt wide — too thin to read at a glance.
///
/// - `recording`: on battery, the mics go to disk but nothing is transcribed — a 🟠,
///   steady.
/// - `pause`: on battery, not recording — listening for voice, or switched off from the
///   menu — a 🟥 that blinks slowly; `lit: false` is the dark half of the beat, which
///   keeps the column so the icons right of it never shift.
enum MicOverlay: Equatable {
    case none
    case recording
    case pause(lit: Bool)

    /// The microphone's own square.
    static let micSide: CGFloat = 18
    /// The column the mark gets, right of the microphone: room for a whole emoji.
    static let column: CGFloat = 13
    /// The mark's side, centred in the column.
    static let markSide: CGFloat = 11

    /// The whole icon: the mic's square, plus the column when there is a mark.
    static func canvas(_ overlay: MicOverlay) -> NSSize {
        NSSize(width: micSide + (overlay == .none ? 0 : column), height: micSide)
    }

    static func emoji(_ overlay: MicOverlay) -> String? {
        switch overlay {
        case .none, .pause(lit: false): return nil
        case .recording: return "🟠"
        case .pause(lit: true): return "🟥"
        }
    }

    /// Draws the mark into the current focus, in the column right of the mic.
    static func draw(_ overlay: MicOverlay, dark: Bool) {
        guard let emoji = emoji(overlay) else { return }
        // Size the font so the glyph's advance is `markSide`, whatever the emoji font's
        // own padding at this size.
        let probe: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10)]
        let probeWidth = max(1, (emoji as NSString).size(withAttributes: probe).width)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10 * markSide / probeWidth)]
        let size = (emoji as NSString).size(withAttributes: attrs)
        (emoji as NSString).draw(at: NSPoint(x: micSide + (column - size.width) / 2,
                                             y: (micSide - size.height) / 2),
                                 withAttributes: attrs)
    }
}
