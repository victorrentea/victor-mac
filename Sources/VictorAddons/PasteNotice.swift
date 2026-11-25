import Cocoa

/// 📋 A participant sent text from Training Assistant's Participant View
/// (the daemon's `paste_received` WS message): a bottom-left pill offers it to copy.
///
/// Victor (2026-11-25): *"cu buton de copy, persistentă până când le dau dismiss,
/// să nu facă dismiss singură"*. So: no countdown (a pinned pill, never pushed out
/// of the stack), one pill per paste, **Copy** on top puts the whole text on the
/// clipboard and leaves the pill up (marked ✅), **Dismiss** below takes it away.
/// `clickOnly`: he works in that corner, a resting cursor must not copy or close.
final class PasteNotice {
    private let screensProvider: () -> [NSScreen]
    /// Every pill still up, so none is released (and vanishes) while on screen.
    private var banners: [ObjectIdentifier: BottomLeftBanner] = [:]

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.pillScreens }) {
        self.screensProvider = screensProvider
    }

    /// The pill's words: who sent it and the first line, cut to fit. Pure.
    static func text(sender: String, text: String, copied: Bool = false) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var first = lines.first ?? ""
        let maxChars = 60
        if first.count > maxChars { first = String(first.prefix(maxChars)) + "…" }
        let more = lines.count > 1 ? " (+\(lines.count - 1) lines)" : ""
        return "\(copied ? "✅" : "📋") \(sender): \(first)\(more)"
    }

    /// Main thread.
    func show(sender: String, text: String) {
        overlayInfo("📋 paste from \(sender) (\(text.count) chars) — pill up")
        let b = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
        let id = ObjectIdentifier(b)
        banners[id] = b
        b.clickOnly = true
        let present: (Bool) -> Void = { [weak b] copied in
            b?.show(text: Self.text(sender: sender, text: text, copied: copied),
                    font: NSFont.systemFont(ofSize: 20),
                    autoAction: .copy, clickAction: .dismiss)
        }
        // Top button (no countdown fills it): copy, and stay up for another copy.
        b.onHoverCountdownExpired = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            overlayInfo("📋 copied the paste from \(sender)")
            present(true)   // re-show re-arms both buttons
        }
        b.onHover = { [weak self, weak b] in
            b?.dismissSinking()
            self?.banners[id] = nil
        }
        present(false)
    }
}
