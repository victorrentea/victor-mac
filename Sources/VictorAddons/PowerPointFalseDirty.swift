import AppKit
import Foundation

/// 🧼 Decides when a deck's "unsaved" mark is PowerPoint's own doing and can be cleared.
///
/// A deck with the Victor Tools pane pinned (`powerpoint-addons/pin-deck.py`) comes up
/// already marked as modified when it is the document PowerPoint **starts** with: measured
/// 2026-11-18 on copies, unsaved from the first second on a cold start, clean when PowerPoint
/// was already running, clean without the pinned pane. Closing it then asks to save a deck
/// nobody touched, and AutoSave rewrites it a minute later.
///
/// So: a deck unsaved in the very first sample that shows it, in a PowerPoint that launched
/// moments ago — and after this watcher did, so a restart of Victor Mac next to a deck
/// with real edits never qualifies. Pure, so it is unit-tested.
struct PowerPointFalseDirtyPolicy {
    /// From PowerPoint's launch to the deck being on screen: a 16 MB deck takes ~10 s.
    var launchWindow: TimeInterval = 90
    let started: Date
    private var seen: Set<String> = []

    init(started: Date) { self.started = started }

    /// The path whose unsaved mark to clear now, if any.
    mutating func consume(_ s: PowerPointSample, appLaunched: Date?) -> String? {
        guard let path = s.path, path.hasPrefix("/") else {
            if s.deck.isEmpty { seen = [] }  // PowerPoint gone: the next start is a new story
            return nil
        }
        guard seen.insert(path).inserted else { return nil }
        guard !s.saved, !s.deck.localizedCaseInsensitiveContains("recover"),
              let launched = appLaunched, launched > started,
              s.at.timeIntervalSince(launched) <= launchWindow else { return nil }
        return path
    }
}

final class PowerPointFalseDirty {
    private var policy = PowerPointFalseDirtyPolicy(started: Date())
    private let queue = DispatchQueue(label: "ro.victorrentea.ppt-false-dirty", qos: .utility)

    func consume(_ sample: PowerPointSample) {
        queue.async { [self] in
            let launched = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.microsoft.Powerpoint").first?.launchDate
            if let path = policy.consume(sample, appLaunched: launched) { Self.markSaved(path) }
        }
    }

    private static func markSaved(_ path: String) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Microsoft PowerPoint"
            repeat with k from 1 to (count of presentations)
                if (full name of presentation k) is "\(escaped)" then
                    set saved of presentation k to true
                    return "cleared"
                end if
            end repeat
        end tell
        return "not open"
        """
        let r = AppleScriptRunner.runDetailed(script, timeout: 15)
        overlayInfo("FalseDirty: \(URL(fileURLWithPath: path).lastPathComponent) unsaved at launch → \(r.output ?? r.error ?? "?")")
    }
}
