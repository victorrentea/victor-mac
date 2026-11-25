import AppKit
import ApplicationServices
import Foundation

/// Where the text caret is in the app Victor is typing in, and what the text
/// around it looks like — read through Accessibility, for the ⌘⇧V bubble
/// (`ClipboardHistoryOverlay`, 2026-11-25, Victor: *"a bubble on top of the
/// cursor position … with the same font/face/weight around the cursor"*).
///
/// **`nil` means "the bezel"**, never "no history": an app that exposes no
/// focused text element, no selected range or a nonsense rectangle (Chrome
/// before its AX tree is built, a canvas-drawn editor, a game) simply gets the
/// centred bezel it had before.
///
/// **Bounded by a 0.15 s messaging timeout per call.** It runs on the main
/// thread on the first ⌘⇧V, and an app that hangs on AX must cost at most a
/// beat before the bezel shows instead.
struct CaretContext: Equatable {
    /// The caret, in **Cocoa** global coordinates (origin bottom-left of the
    /// primary screen) — what `NSWindow.setFrame` wants.
    var rect: CGRect
    /// PostScript name (`Menlo-Bold`, `SFMono-Regular`), so weight and face come
    /// along with the family.
    var fontName: String?
    var fontSize: CGFloat?
    var foreground: NSColor?
    var background: NSColor?
    /// A terminal: AX gives no font there (Terminal.app answers
    /// `AXAttributedStringForRange` with "unsupported"), but it is always a
    /// monospaced grid, so the bubble uses the system mono font sized from the
    /// cell. 1.28 cell-height-per-point is the ratio measured on Victor's
    /// profile — 23 pt cell at 18 pt (`TerminalFontSize`).
    var monospaced = false

    /// The font the bubble writes the clip in: the one at the caret when AX
    /// named it, otherwise the system font at the size the caret's height
    /// implies (a caret is about one line tall, a line about 1.2 em).
    func font() -> NSFont {
        if fontName == nil, monospaced {
            let size = CaretBubblePolicy.fontSize(reported: rect.height / 1.28, caretHeight: rect.height)
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let size = CaretBubblePolicy.fontSize(reported: fontSize, caretHeight: rect.height)
        if let fontName, let font = NSFont(name: fontName, size: size) { return font }
        return .systemFont(ofSize: size)
    }
}

enum CaretLocator {

    /// Apps whose text is a character grid — see `CaretContext.monospaced`.
    static let terminalBundleIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]

    static func current() -> CaretContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let element = focusedElement(pid: app.processIdentifier) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location >= 0 else { return nil }

        guard let axRect = caretRect(in: element, at: selection.location),
              let rect = CaretBubblePolicy.cocoaRect(fromAX: axRect,
                                                     primaryHeight: NSScreen.screens.first?.frame.height ?? 0,
                                                     screens: NSScreen.physical.map(\.frame)) else { return nil }

        // The character *before* the caret is the one the paste continues; at
        // the very start of a field there is none, so the one after it.
        let styleAt = selection.location > 0 ? selection.location - 1 : selection.location
        let style = attributes(in: element, at: styleAt)
        return CaretContext(rect: rect,
                            fontName: style.fontName, fontSize: style.fontSize,
                            foreground: style.foreground, background: style.background,
                            monospaced: terminalBundleIDs.contains(app.bundleIdentifier ?? ""))
    }

    // MARK: - AX plumbing

    /// The focused element of the frontmost app. Electron apps (VS Code, Slack)
    /// build their AX tree only once someone sets `AXManualAccessibility` on
    /// them; it is harmless, so on a miss it is set and the read tried once more.
    /// (`AXEnhancedUserInterface` — Chrome's switch — is deliberately not
    /// touched: it breaks window animations and Rectangle-style tiling.)
    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        func read() -> AXUIElement? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
                  let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        if let element = read() { return element }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return read()
    }

    /// A zero-length range is the caret itself, and most Cocoa text views
    /// answer it with a 0-wide, one-line-tall rect. Some answer it with nothing
    /// or with a 0×0 rect; then the character before the caret is measured
    /// and its right edge used, or the one after it and its left edge.
    private static func caretRect(in element: AXUIElement, at location: Int) -> CGRect? {
        if let rect = bounds(in: element, location: location, length: 0), rect.height >= 4 { return rect }
        if location > 0, let before = bounds(in: element, location: location - 1, length: 1), before.height >= 4 {
            return CGRect(x: before.maxX, y: before.minY, width: 0, height: before.height)
        }
        if let after = bounds(in: element, location: location, length: 1), after.height >= 4 {
            return CGRect(x: after.minX, y: after.minY, width: 0, height: after.height)
        }
        return nil
    }

    private static func bounds(in element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &raw) == .success,
            let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private struct Style {
        var fontName: String?
        var fontSize: CGFloat?
        var foreground: NSColor?
        var background: NSColor?
    }

    /// `AXAttributedStringForRange` on one character: its `AXFont` dictionary
    /// (`AXFontName`, `AXFontSize`) and its colours, when the app says.
    private static func attributes(in element: AXUIElement, at location: Int) -> Style {
        var range = CFRange(location: location, length: 1)
        guard let param = AXValueCreate(.cfRange, &range) else { return Style() }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXAttributedStringForRangeParameterizedAttribute as CFString, param, &raw) == .success,
            let value = raw, CFGetTypeID(value) == CFAttributedStringGetTypeID() else { return Style() }
        let string = value as! NSAttributedString
        guard string.length > 0 else { return Style() }
        let attrs = string.attributes(at: 0, effectiveRange: nil)
        var style = Style()
        if let font = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] {
            style.fontName = font["AXFontName"] as? String
            style.fontSize = (font["AXFontSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        style.foreground = color(attrs[NSAttributedString.Key("AXForegroundColor")])
        style.background = color(attrs[NSAttributedString.Key("AXBackgroundColor")])
        return style
    }

    private static func color(_ value: Any?) -> NSColor? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CGColor.typeID else { return nil }
        return NSColor(cgColor: value as! CGColor)
    }
}

/// The pure half of the bubble: is this AX rectangle believable, which font
/// size, which colours, and where the bubble goes. Unit-tested.
enum CaretBubblePolicy {

    /// AX hands rectangles in top-left-origin global coordinates (the primary
    /// screen's top-left is 0,0, y grows down); Cocoa wants bottom-left-origin.
    /// Returns `nil` for a rectangle no caret could be: zero/negative/huge
    /// height, non-finite, or not on any screen — a 0,0,0,0 is the usual way an
    /// app says "I don't know" while still returning `.success`.
    static func cocoaRect(fromAX ax: CGRect, primaryHeight: CGFloat, screens: [CGRect]) -> CGRect? {
        guard ax.origin.x.isFinite, ax.origin.y.isFinite, ax.width.isFinite, ax.height.isFinite,
              ax.height >= 4, ax.height <= 300, ax.width >= 0, ax.width <= 4000,
              !(ax.origin == .zero && ax.width == 0) else { return nil }
        let rect = CGRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
        let point = CGPoint(x: rect.minX, y: rect.midY)
        guard screens.contains(where: { $0.contains(point) }) else { return nil }
        return rect
    }

    /// The point size of the text at the caret: what AX said, else the caret's
    /// own height read back as one line (≈ 1.2 em). Held between 11 and 40 so a
    /// tiny caption or a slide-sized title still gives a readable bubble.
    static func fontSize(reported: CGFloat?, caretHeight: CGFloat) -> CGFloat {
        let raw = reported.flatMap { $0 > 0 ? $0 : nil } ?? (caretHeight / 1.2)
        return min(40, max(11, raw.rounded()))
    }

    /// The document's own colours, so the clip looks the way it will once
    /// pasted — but only both together and only when they are far enough apart
    /// to read: a foreground alone (the common case: black text, no background
    /// attribute) on the bubble's dark card would be invisible.
    static func colors(foreground: NSColor?, background: NSColor?,
                       fallbackText: NSColor, fallbackBackground: NSColor) -> (text: NSColor, background: NSColor) {
        guard let fg = foreground?.usingColorSpace(.sRGB), let bg = background?.usingColorSpace(.sRGB),
              bg.alphaComponent > 0.5,
              contrast(luminance(fg), luminance(bg)) >= 3 else {
            return (fallbackText, fallbackBackground)
        }
        return (fg, bg.withAlphaComponent(0.97))
    }

    static func luminance(_ color: NSColor) -> CGFloat {
        func channel(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    static func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    struct Placement: Equatable {
        /// The bubble window's frame, tail included.
        var frame: CGRect
        /// True when the bubble sits above the caret (tail on its bottom edge,
        /// pointing down); false when there was no room and it went below.
        var above: Bool
        /// Where the tail's tip is, measured from the bubble's left edge.
        var tailX: CGFloat
    }

    /// **Above the caret**, so the line being typed stays readable, with the
    /// clip's first character over the caret's x — the text appears roughly
    /// where it is about to be pasted. Below the caret when the screen has no
    /// room above (the first line of a window at the top). Slid sideways to
    /// stay on the screen, the tail still pointing at the caret.
    ///
    /// - Parameters:
    ///   - size: the bubble with its tail.
    ///   - contentInset: how far the clip's first character sits from the
    ///     bubble's left edge.
    static func place(size: CGSize, caret: CGRect, visible: CGRect,
                      contentInset: CGFloat, gap: CGFloat = 4, margin: CGFloat = 6,
                      tailHalfWidth: CGFloat = 9, cornerRadius: CGFloat = 12) -> Placement {
        let roomAbove = visible.maxY - (caret.maxY + gap)
        let roomBelow = (caret.minY - gap) - visible.minY
        let above = roomAbove >= size.height || roomAbove >= roomBelow
        var y = above ? caret.maxY + gap : caret.minY - gap - size.height
        y = min(max(y, visible.minY + margin), visible.maxY - margin - size.height)

        var x = caret.minX - contentInset
        x = min(max(x, visible.minX + margin), visible.maxX - margin - size.width)

        let edge = cornerRadius + tailHalfWidth
        let tailX = min(max(caret.minX - x, edge), max(edge, size.width - edge))
        return Placement(frame: CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height),
                         above: above, tailX: tailX.rounded())
    }
}

/// `GET /test/caret` — what the bubble would see right now in the front app,
/// as JSON. The only way to check the AX read without pressing ⌘⇧V.
enum CaretLocatorProbe {
    static func json() -> String {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        guard let caret = CaretLocator.current() else {
            return "{\"app\":\"\(app)\",\"caret\":null}"
        }
        let font = caret.font()
        func hex(_ c: NSColor?) -> String {
            guard let c = c?.usingColorSpace(.sRGB) else { return "null" }
            return String(format: "\"#%02X%02X%02X\"", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                          Int(c.blueComponent * 255))
        }
        return String(format: "{\"app\":\"%@\",\"caret\":{\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f},"
                      + "\"axFont\":\"%@\",\"axSize\":%@,\"font\":\"%@\",\"size\":%.0f,\"fg\":%@,\"bg\":%@}",
                      app, caret.rect.minX, caret.rect.minY, caret.rect.width, caret.rect.height,
                      caret.fontName ?? "", caret.fontSize.map { String(format: "%.1f", $0) } ?? "null",
                      font.fontName, font.pointSize, hex(caret.foreground), hex(caret.background))
    }
}
