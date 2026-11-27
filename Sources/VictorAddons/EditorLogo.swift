import Cocoa

/// 📄 → the editor's own logo in the "file opened" banner (2026-11-27, Victor:
/// *"afișează logoul în loc de 📄 în overlay"*).
///
/// Both reporters — `victor-vsc`'s `open-file-reporter.js` and `live-coding`'s
/// `OpenFileReporter.kt` — POST the same payload to `/intellij/file-opened`,
/// with nothing saying which editor sent it. Both only fire from a *focused*
/// window after a 5 s dwell, so the frontmost app at that moment is the sender:
/// its icon goes in front of the file name. Anything else in front (a reporter
/// racing a ⌘Tab) keeps the 📄, which then still says "a file".
enum EditorLogo {
    /// Bundle ids of the editors whose reporters post here.
    static func isEditor(_ bundleId: String?) -> Bool {
        guard let id = bundleId else { return false }
        return id.hasPrefix("com.microsoft.VSCode")      // VS Code, Insiders
            || id.hasPrefix("com.jetbrains.")            // IntelliJ IDEA (Ultimate/CE), …
    }

    /// The banner's words: just the file name behind a logo, `📄 name` without one.
    static func bannerText(file: String, hasLogo: Bool) -> String {
        let name = (file as NSString).lastPathComponent
        return hasLogo ? name : "📄 " + name
    }

    /// The frontmost app's icon, if it is one of the editors.
    static func frontmostEditorIcon() -> NSImage? {
        let app = NSWorkspace.shared.frontmostApplication
        return isEditor(app?.bundleIdentifier) ? app?.icon : nil
    }
}
