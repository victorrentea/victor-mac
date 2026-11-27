import Cocoa

/// **The DJI mic drawn as DJI's own logo in the 🎙️ menu** (2026-11-27, Victor:
/// *"change this icon [🎤] with the DJI logo"*). `MicRoster`'s glyph stays 🎤 —
/// it is the contract with `whisper_runner.py` and Walkie Talkie — so only the
/// menu's *drawing* changes: every 🎤 in a menu title becomes the "dji" wordmark,
/// inline in the text so the rows keep their alignment (an `NSMenuItem.image`
/// would indent every other row of the menu).
///
/// `mic_dji.png` is an alpha mask (the wordmark from Wikimedia's
/// `DJI_Innovations_logo.svg`, cropped), inked at draw time in the label colour,
/// so it reads on a light and a dark menu alike — DJI's blue would vanish on the
/// blue highlight of a hovered row.
enum DjiLogo {
    static let glyph = "🎤"

    /// Logo height in points; the letters' baseline sits 76 % down the picture
    /// (the "j" hangs below it), so a 13 pt logo stands ~10 pt tall like the menu's capitals.
    private static let height: CGFloat = 13
    private static let baseline: CGFloat = 0.76

    private static let mask: NSImage? = Bundle.module.url(forResource: "mic_dji", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    private static func inked(_ color: NSColor) -> NSImage? {
        mask.map { m in
            let size = NSSize(width: (height * m.size.width / m.size.height).rounded(), height: height)
            return NSImage(size: size, flipped: false) { r in
                m.draw(in: r)
                color.set()   // a dynamic colour, resolved when the menu draws
                r.fill(using: .sourceAtop)
                return true
            }
        }
    }
    private static let live = inked(.labelColor)
    private static let grey = inked(.disabledControlTextColor)

    /// `title` as the menu draws it: the menu font, each 🎤 replaced by the logo.
    /// An attributed title is not greyed by AppKit on a disabled row ("grey alone says
    /// it is absent"), so `enabled: false` greys the words and the logo itself.
    /// A missing resource leaves the emoji, so the row never goes blank.
    static func menuTitle(_ title: String, enabled: Bool = true,
                          font: NSFont = NSFont.menuFont(ofSize: 0)) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if !enabled { attrs[.foregroundColor] = NSColor.disabledControlTextColor }
        guard let logo = enabled ? live : grey, title.contains(glyph) else {
            return NSAttributedString(string: title, attributes: attrs)
        }
        let out = NSMutableAttributedString()
        for (i, part) in title.components(separatedBy: glyph).enumerated() {
            if i > 0 {
                let att = NSTextAttachment()
                att.image = logo
                att.bounds = NSRect(x: 0, y: -(1 - baseline) * height,
                                    width: logo.size.width, height: logo.size.height)
                out.append(NSAttributedString(attachment: att))
            }
            out.append(NSAttributedString(string: part, attributes: attrs))
        }
        return out
    }

    /// The words of `item`'s title with the logo spelled 🎤 again: once an attributed
    /// title is set, `title` reads its attachment as U+FFFC, and `/test/state` must
    /// keep comparing row for row with Walkie Talkie's menu.
    static func plainTitle(_ item: NSMenuItem) -> String {
        item.title.replacingOccurrences(of: "\u{FFFC}", with: glyph)
    }

    /// Sets `item`'s title, with the logo when it carries a 🎤. Set `isEnabled` first.
    static func apply(_ title: String, to item: NSMenuItem) {
        item.title = title
        item.attributedTitle = title.contains(glyph) ? menuTitle(title, enabled: item.isEnabled) : nil
    }
}
