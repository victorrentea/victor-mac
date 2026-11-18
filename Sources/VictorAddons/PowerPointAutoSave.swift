import CoreGraphics
import Foundation

/// 💾 Decides when an edited deck gets a real save. Pure, so the rules are unit-tested.
/// A deck that stays unsaved for `dirtySeconds` is saved at the first moment Victor's hands
/// have been off the mouse and keyboard for `idleSeconds`, so a save never lands mid-word,
/// and never during a slide show.
struct PowerPointAutoSavePolicy {
    var dirtySeconds: TimeInterval = 60
    var idleSeconds: TimeInterval = 3
    private var dirtyPath: String?
    private var dirtySince: Date?

    /// The path to save now, if any.
    mutating func consume(_ s: PowerPointSample, idle: TimeInterval) -> String? {
        guard !s.saved, let path = s.path, PowerPointDeck.hasFile(path) else {
            dirtyPath = nil
            dirtySince = nil
            return nil
        }
        guard path == dirtyPath, let since = dirtySince else {
            dirtyPath = path
            dirtySince = s.at
            return nil
        }
        guard !s.presenting, idle >= idleSeconds, s.at.timeIntervalSince(since) >= dirtySeconds else { return nil }
        dirtySince = s.at  // a save Drive refused shows up as still unsaved: try again a full period later
        return path
    }
}

/// 💾 PowerPoint's own AutoSave only works on OneDrive and SharePoint, and its AutoRecover
/// writes a separate recovery file, so a deck on Google Drive stays as it was until ⌘S.
final class PowerPointAutoSave {
    private var policy = PowerPointAutoSavePolicy()
    private let queue = DispatchQueue(label: "ro.victorrentea.ppt-autosave", qos: .utility)

    func consume(_ sample: PowerPointSample) {
        queue.async { [self] in
            if let path = policy.consume(sample, idle: Self.secondsSinceLastInput()) {
                PowerPointDeck.save(path, reason: "AutoSave")
            }
        }
    }

    private static func secondsSinceLastInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

enum PowerPointDeck {
    /// PowerPoint's full name of a deck never saved is a bare "Presentation1": no file behind it.
    static func hasFile(_ path: String?) -> Bool { path?.hasPrefix("/") ?? false }

    /// Saves the open deck at `path`. A refused save raises nothing and `save` itself reports no
    /// error, measured on a locked file: only the deck still being unsaved afterwards tells.
    static func save(_ path: String, reason: String) {
        // Scripted `save` on a deck never saved does not ask where: it writes a file named after
        // the first slide's title into PowerPoint's sandbox and marks the deck saved, so closing
        // it no longer warns (2026-11-18, a new deck lost that way through SlidesSeen).
        guard hasFile(path) else { return }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Microsoft PowerPoint"
            repeat with k from 1 to (count of presentations)
                if (full name of presentation k) is "\(escaped)" then
                    save presentation k
                    if saved of presentation k then return "saved"
                    return "refused"
                end if
            end repeat
        end tell
        return "not open"
        """
        let r = AppleScriptRunner.runDetailed(script, timeout: 30)
        overlayInfo("\(reason): save \(URL(fileURLWithPath: path).lastPathComponent) → \(r.output ?? r.error ?? "?")")
    }
}
