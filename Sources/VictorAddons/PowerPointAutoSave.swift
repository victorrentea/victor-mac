import CoreGraphics
import Foundation

/// 💾 Decides when an edited deck gets a real save. Pure, so the rules are unit-tested.
/// A deck that stays unsaved for `dirtySeconds` (3 min since 2026-11-20: every save now also
/// makes the training-assistant daemon print the changed slides) is saved at the first moment Victor's hands
/// have been off the mouse and keyboard for `idleSeconds`, so a save never lands mid-word,
/// and never during a slide show. While Google Drive still uploads the previous save
/// (`uploading`) it waits, without restarting the clock: PowerPoint would refuse that save.
struct PowerPointAutoSavePolicy {
    var dirtySeconds: TimeInterval = 180
    var idleSeconds: TimeInterval = ScriptedSaveMoment.handsPausedSeconds
    private var dirtyPath: String?
    private var dirtySince: Date?

    /// The path to save now, if any.
    mutating func consume(_ s: PowerPointSample, idle: TimeInterval, uploading: Bool = false) -> String? {
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
        guard !s.presenting, !uploading, idle >= idleSeconds,
              s.at.timeIntervalSince(since) >= dirtySeconds else { return nil }
        dirtySince = s.at  // a save that was refused shows up as still unsaved: try again a full period later
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
            let uploading = sample.path.map(PowerPointDeck.uploading) ?? false
            if let path = policy.consume(sample, idle: ScriptedSaveMoment.secondsSinceLastInput(), uploading: uploading) {
                PowerPointDeck.save(path, reason: "AutoSave")
            }
        }
    }
}

/// 💾 When a save made by this app (AutoSave, SlidesSeen) may run, so that Victor's own ⌘S
/// always wins (2026-11-23: "PowerPoint says the file cannot be saved, then an auto-save happens").
///
/// Google Drive uploads a saved deck through a temporary hard link (`DriveSpotlightKeeper`),
/// held 7–15 s for a 16 MB deck, longer on a slow network, and PowerPoint refuses to save a
/// file that has a second link ("The document could not be saved", measured 2026-11-18). So
/// **every save shuts the next one out for those seconds** — and a save of ours, made while
/// he is still working on the slide, shut out the ⌘S he pressed right after his edit. The
/// SlidesSeen save used to land 7 s after he reached a slide, whatever his hands were doing.
///
/// So a scripted save waits for his hands to pause (he is then not about to press ⌘S on what
/// he just typed), and never starts while Drive still uploads the previous save: PowerPoint
/// would refuse it, as it did in the log ("→ refused" seconds after another save).
/// Pure, so the rule is unit-tested.
enum ScriptedSaveMoment {
    static let handsPausedSeconds: TimeInterval = 3

    /// `frontmost`: PowerPoint is the app in front. Behind another app nothing he types reaches
    /// it, ⌘S included, so there his hands do not matter.
    static func allows(idle: TimeInterval, frontmost: Bool, uploading: Bool) -> Bool {
        !uploading && (idle >= handsPausedSeconds || !frontmost)
    }

    static func secondsSinceLastInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

enum PowerPointDeck {
    /// PowerPoint's full name of a deck never saved is a bare "Presentation1": no file behind it.
    static func hasFile(_ path: String?) -> Bool { path?.hasPrefix("/") ?? false }

    /// True when the deck at `path` is open with unsaved edits and no slide show runs: the deck
    /// a qualified slide belonged to, when another deck has become the active one since.
    static func needsSave(_ path: String) -> Bool {
        guard hasFile(path) else { return false }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        if application "Microsoft PowerPoint" is not running then return "not running"
        tell application "Microsoft PowerPoint"
            if (count of slide show windows) > 0 then return "slide show"
            repeat with k from 1 to (count of presentations)
                if (full name of presentation k) is "\(escaped)" then
                    if saved of presentation k then return "saved"
                    return "unsaved"
                end if
            end repeat
        end tell
        return "not open"
        """
        return AppleScriptRunner.runDetailed(script, timeout: 10).output == "unsaved"
    }

    /// True while Google Drive holds the file through its upload hard link: the seconds after
    /// a save in which PowerPoint refuses the next one (see `ScriptedSaveMoment`).
    static func uploading(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_nlink > 1
    }

    /// AutoSave and SlidesSeen run on their own queues and can pick the same pause of his hands.
    private static let oneSaveAtATime = NSLock()

    /// Saves the open deck at `path`, if it still has unsaved edits by the time PowerPoint is
    /// asked: he may have pressed ⌘S since the probe that called for the save. A refused save
    /// raises nothing and `save` itself reports no error, measured on a locked file: only the
    /// deck still being unsaved afterwards tells. Returns whether the deck is saved now.
    @discardableResult
    static func save(_ path: String, reason: String) -> Bool {
        // Scripted `save` on a deck never saved does not ask where: it writes a file named after
        // the first slide's title into PowerPoint's sandbox and marks the deck saved, so closing
        // it no longer warns (2026-11-18, a new deck lost that way through SlidesSeen).
        guard hasFile(path) else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent
        oneSaveAtATime.lock(); defer { oneSaveAtATime.unlock() }
        // The last gate, for every caller: PowerPoint would refuse it, and it must not be
        // under way when Victor presses ⌘S.
        guard !uploading(path) else {
            overlayInfo("\(reason): save \(name) → skipped, Drive still uploads the previous save")
            return false
        }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Microsoft PowerPoint"
            repeat with k from 1 to (count of presentations)
                if (full name of presentation k) is "\(escaped)" then
                    if saved of presentation k then return "already saved"
                    save presentation k
                    if saved of presentation k then return "saved"
                    return "refused"
                end if
            end repeat
        end tell
        return "not open"
        """
        let before = ScriptedSaveLog.mtime(of: path)
        let previous = ScriptedSaveLog.started(path)
        let r = AppleScriptRunner.runDetailed(script, timeout: 30)
        if ScriptedSaveLog.wrote(answer: r.output, before: before, after: ScriptedSaveLog.mtime(of: path)) {
            ScriptedSaveLog.finished(path)
        } else {
            ScriptedSaveLog.restore(path, previous)
        }
        overlayInfo("\(reason): save \(name) → \(r.output ?? r.error ?? "?")")
        return r.output == "saved" || r.output == "already saved"
    }
}

/// 🖨 Which saves were made by this app (AutoSave, SlidesSeen) rather than by Victor's ⌘S, in
/// `~/.victor-addons/powerpoint-scripted-saves.json`: `{path: {"started": epoch, "mtime": epoch?}}`.
/// The training-assistant daemon prints the changed slides in PowerPoint after every save, and
/// that print shows a progress bar; after a scripted save it waits until PowerPoint is in the
/// background (Victor, 2026-11-20). `mtime` is the file's after the save; while it is missing
/// a save is under way, so a daemon that sees the new mtime first still reads it as scripted.
enum ScriptedSaveLog {
    static var fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".victor-addons", isDirectory: true)
        .appendingPathComponent("powerpoint-scripted-saves.json")
    private static let lock = NSLock()

    /// A save under way that never wrote its end (the app killed mid-save) stops counting
    /// after this; the daemon's `save_origin.py` uses the same window.
    static let underWaySeconds: TimeInterval = 120
    /// A day is plenty: the daemon looks at a save within seconds of it.
    static let keptSeconds: TimeInterval = 86400

    static func mtime(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Notes a save as under way. Returns the entry it replaces, for `restore`.
    @discardableResult
    static func started(_ path: String, at now: Date = Date()) -> [String: Any]? {
        let previous = read()[path]
        update(path, ["started": now.timeIntervalSince1970])
        return previous
    }

    static func finished(_ path: String, at now: Date = Date()) {
        var entry: [String: Any] = ["started": (read()[path]?["started"] as? Double) ?? now.timeIntervalSince1970]
        entry["mtime"] = (mtime(of: path) ?? now).timeIntervalSince1970
        update(path, entry)
    }

    /// Whether the save just asked of PowerPoint wrote the file, and so is this app's to claim.
    /// Told by the file, not by the answer: a save that wrote it can still answer "refused"
    /// (he typed again before PowerPoint was asked whether the deck is saved), and left
    /// unclaimed the daemon would print it in front, as if he had pressed ⌘S, and the badge
    /// would say "by you". A refused one that wrote nothing left the file with the mtime of
    /// the save before it — his ⌘S, perhaps — which must not be claimed either.
    static func wrote(answer: String?, before: Date?, after: Date?) -> Bool {
        answer != "already saved" && after != nil && after != before
    }

    /// The save wrote nothing: the entry goes back to what it said before `started`.
    static func restore(_ path: String, _ previous: [String: Any]?) {
        update(path, previous)
    }

    /// True when the save that gave the file this `mtime` was made by this app, not by ⌘S.
    /// The same rule as the daemon's `is_scripted_save`.
    static func isScripted(entry: [String: Any]?, mtime: Date) -> Bool {
        guard let entry, let started = entry["started"] as? Double else { return false }
        let m = mtime.timeIntervalSince1970
        guard let after = entry["mtime"] as? Double else {
            return started - 1 <= m && m <= started + underWaySeconds
        }
        return abs(after - m) < 1
    }

    static func read() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        return json
    }

    private static func update(_ path: String, _ entry: [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        var all = read()
        all[path] = entry
        let cutoff = Date().timeIntervalSince1970 - keptSeconds
        all = all.filter { (($0.value["started"] as? Double) ?? 0) > cutoff }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys, .withoutEscapingSlashes])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            overlayError("ScriptedSaveLog: could not write \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
