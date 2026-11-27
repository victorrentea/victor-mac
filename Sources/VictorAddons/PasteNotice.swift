import Cocoa

/// 📋 A participant sent text from Training Assistant's Participant View
/// (the daemon's `paste_received` WS message): a bottom-left pill offers it to copy.
///
/// Victor (2026-11-25): *"cu buton de copy, persistentă până când le dau dismiss,
/// să nu facă dismiss singură"*. So: no countdown (a pinned pill, never pushed out
/// of the stack), one pill per paste, **Copy** on top puts the whole text on the
/// clipboard and leaves the pill up (marked ✅), **Dismiss** below takes it away.
/// `clickOnly`: he works in that corner, a resting cursor must not copy or close.
///
/// 2026-11-27, Victor: *"copy should be copy plus send … that thing goes into the
/// notes that I have opened for this current session"*. The top button starts as
/// **Copy + Send**: it copies AND appends the text to the session notes as a `📋`
/// line (`SessionNotesAppender.sendByHand`, the same line ⌘⌃S writes), then the
/// pill floats up and away — Victor: *"if I clicked copy and send, why do I still
/// see them?"*. Gone means sent, so a paste can never be written twice. If the
/// write fails (no session / no notes file) the text is still copied, the failure
/// flashes, and the pill stays up (✅) with Copy + Send for a retry.
///
/// 2026-11-27 (later), Victor: *"it should say: From <name>: … with two buttons:
/// Copy & Dismiss and Copy & Send to all"*. The words lead with `From`, no 📋; the
/// top button **Copy & Dismiss** copies and sinks the pill (nothing written), the
/// bottom one **Copy & Send to all** is the old Copy + Send (copy, append to the
/// notes the participants get, rise away; a failed append keeps the pill).
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
        return "\(copied ? "✅ " : "")From \(sender): \(first)\(more)"
    }

    /// Main thread.
    /// `sendToNotes` writes the text into the session notes and says whether it
    /// landed — injectable for tests; the app's is `SessionNotesAppender.sendByHand`.
    func show(sender: String, text: String,
              sendToNotes: @escaping (String) -> Bool = { SessionNotesAppender.sendByHand($0) }) {
        overlayInfo("📋 paste from \(sender) (\(text.count) chars) — pill up")
        let b = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
        let id = ObjectIdentifier(b)
        banners[id] = b
        b.clickOnly = true
        let present: (Bool) -> Void = { [weak b] copied in
            b?.show(text: Self.text(sender: sender, text: text, copied: copied),
                    font: NSFont.systemFont(ofSize: 20),
                    autoAction: .copyDismiss, clickAction: .copySend)
        }
        let copy = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        // Top button (no countdown fills it): copy and sink away.
        b.onHoverCountdownExpired = { [weak self, weak b] in
            copy()
            overlayInfo("📋 copied + dismissed the paste from \(sender)")
            b?.dismissSinking()
            self?.banners[id] = nil
        }
        // Bottom button: copy, append to the notes everyone gets, and rise away.
        // A failed append keeps the pill for another try.
        b.onHover = { [weak self, weak b] in
            copy()
            if sendToNotes(text) {
                overlayInfo("📋 copied + sent to all (notes) the paste from \(sender)")
                b?.dismissRisingFade()
                self?.banners[id] = nil
            } else {
                overlayInfo("📋 copied the paste from \(sender); notes NOT written")
                present(true)   // re-show re-arms both buttons
            }
        }
        present(false)
    }
}
