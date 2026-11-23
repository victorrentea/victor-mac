import CryptoKit
import Foundation

/// One probe of PowerPoint, as `PowerPointMonitor` saw it.
struct PowerPointSample: Equatable {
    let at: Date
    let deck: String
    let path: String?
    let slide: Int
    /// PowerPoint's `slide ID` — the `<p:sldId id>` of the .pptx. Unlike `slide`
    /// (the position) it survives inserting, deleting and reordering slides.
    let slideID: Int?
    let presenting: Bool
    let frontmost: Bool
    let saved: Bool

    static func gone(at: Date) -> PowerPointSample {
        PowerPointSample(at: at, deck: "", path: nil, slide: 0, slideID: nil,
                         presenting: false, frontmost: false, saved: true)
    }
}

/// A slide that held the screen without interruption.
struct SlideSpan: Equatable {
    let deck: String
    let path: String?
    let slide: Int
    let slideID: Int
    let presenting: Bool
    let start: Date
    var end: Date
}

/// 📑 Decides what counts as a slide "shown": the same slide, PowerPoint in front,
/// for at least `minSeconds` in a row. Pure, so the thresholds are unit-tested.
struct SlidesSeenPolicy {
    enum Action: Equatable {
        /// Crossed the threshold: now is the moment to save the deck and copy it.
        case qualified(SlideSpan)
        /// The slide left the screen; only qualified spans are reported.
        case closed(SlideSpan)
    }

    var minSeconds: TimeInterval = 7
    private(set) var current: SlideSpan?
    private(set) var qualified = false

    mutating func consume(_ s: PowerPointSample) -> [Action] {
        var out: [Action] = []
        let sameSlide = current.map { s.frontmost && s.path == $0.path && s.slideID == $0.slideID } ?? false
        if sameSlide {
            current!.end = s.at
        } else {
            if let c = current, qualified { out.append(.closed(c)) }
            current = nil
            qualified = false
            if s.frontmost, let id = s.slideID, !s.deck.isEmpty {
                current = SlideSpan(deck: s.deck, path: s.path, slide: s.slide, slideID: id,
                                    presenting: s.presenting, start: s.at, end: s.at)
            }
        }
        if let c = current, !qualified, c.end.timeIntervalSince(c.start) >= minSeconds {
            qualified = true
            out.append(.qualified(c))
        }
        return out
    }
}

/// 📑 What to save when a qualified span closes, so the training-assistant daemon prints the
/// slide in the last form it was shown (Victor, 2026-11-22). Pure, so the cases are unit-tested.
///
/// The sample that closes the span may be about another deck, PowerPoint in the background or
/// PowerPoint gone; its `saved` describes the *active* presentation only, so it decides alone
/// only when the active deck is still the span's.
enum SlidesSeenCloseSave: Equatable {
    /// Nothing to save: no file, PowerPoint gone, a slide show, or already saved.
    case none
    /// The span's deck is the active one and has unsaved edits.
    case save(String)
    /// Another deck is active now: ask PowerPoint about the span's own deck first.
    case saveIfUnsaved(String)

    static func decide(span: SlideSpan, closing s: PowerPointSample) -> SlidesSeenCloseSave {
        guard let path = span.path, PowerPointDeck.hasFile(path) else { return .none }
        guard !s.deck.isEmpty else { return .none }              // .gone: PowerPoint quit or closed every deck
        guard s.path == path else { return .saveIfUnsaved(path) }
        return s.presenting || s.saved ? .none : .save(path)
    }

    /// The save at the 7th second of a slide: only for unsaved edits, never during a slide
    /// show (like AutoSave and the save on leaving), and only at `ScriptedSaveMoment`.
    static func saveWhenQualified(_ s: PowerPointSample, idle: TimeInterval, uploading: Bool) -> Bool {
        !s.saved && !s.presenting
            && ScriptedSaveMoment.allows(idle: idle, frontmost: s.frontmost, uploading: uploading)
    }

    /// True when a slide reported at this probe, with no save of ours, still has edits that
    /// are not on disk: the daemon reads the old form, so the report is repeated once the
    /// deck is saved. Only the active deck's state is known from a probe.
    static func leftUnsaved(span: SlideSpan, now s: PowerPointSample) -> Bool {
        guard let path = span.path, PowerPointDeck.hasFile(path) else { return false }
        return s.path == path && !s.saved
    }

    /// What to do, at one probe, with a slide that was left and not yet reported as `closed`.
    enum Step: Equatable {
        /// His hands are on PowerPoint, or Drive still uploads the previous save: ask again
        /// at the next probe.
        case wait
        /// Report it as it is on disk.
        case send
        case saveThenSend(String)
        /// Another deck is active: ask PowerPoint whether the span's own deck needs the save.
        case askThenSend(String)
    }

    /// The report is not held back for longer than this: past it, the slide goes out as it
    /// is on disk and AutoSave picks the edits up later.
    static let maxWait: TimeInterval = 60

    /// The save on leaving a slide used to run at once — right after the click or key that
    /// left it, so the ⌘S Victor pressed next met a file Drive was still uploading and was
    /// refused. It now waits for `ScriptedSaveMoment`; `sample` is the current probe, so a
    /// ⌘S of his in the meantime turns the save into nothing to do.
    static func step(span: SlideSpan, now sample: PowerPointSample, waited: TimeInterval,
                     idle: TimeInterval, uploading: Bool) -> Step {
        let decision = decide(span: span, closing: sample)
        if decision == .none { return .send }
        guard ScriptedSaveMoment.allows(idle: idle, frontmost: sample.frontmost, uploading: uploading) else {
            return waited >= maxWait ? .send : .wait
        }
        switch decision {
        case .save(let path): return .saveThenSend(path)
        case .saveIfUnsaved(let path): return .askThenSend(path)
        case .none: return .send
        }
    }
}

/// 📑 The `slide_seen` message sent to the training-assistant daemon over the local WebSocket:
/// at the 7 s threshold (`qualified`) and when the slide leaves the screen (`closed`). The
/// daemon keeps, per training session, one PDF page per slide shown, in its last form.
enum SlidesSeenEvent {
    enum Phase: String { case qualified, closed }

    static func payload(_ phase: Phase, span: SlideSpan, at: Date) -> [String: Any]? {
        guard let path = span.path, PowerPointDeck.hasFile(path) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        return ["type": "slide_seen", "phase": phase.rawValue, "path": path, "deck": span.deck,
                "slide_id": span.slideID, "slide": span.slide, "at": iso.string(from: at)]
    }
}

/// 🔎 Which deck to hand back to Spotlight: one seen for the first time, and one that
/// just went from unsaved to saved. On 2026-11-13 Spotlight stopped picking up saves
/// under `~/My Drive` for ~11 h (cause not found) and ⌘Space no longer found the decks
/// saved that day; `mdimport <file>` brought each back in 2 s. Pure, so it is unit-tested.
struct SpotlightReindexPolicy {
    private var saved: [String: Bool] = [:]

    mutating func consume(_ s: PowerPointSample) -> String? {
        guard let path = s.path, !path.isEmpty else { return nil }
        let before = saved.updateValue(s.saved, forKey: path)
        switch before {
        case nil: return s.saved ? path : nil
        case false?: return s.saved ? path : nil
        default: return nil
        }
    }
}

/// What `SlidesSeenRecorder` touches outside itself, so its flow is tested without PowerPoint.
struct SlidesSeenWorld {
    var root: URL = SlidesSeenRecorder.root
    var idle: () -> TimeInterval = ScriptedSaveMoment.secondsSinceLastInput
    var uploading: (String) -> Bool = PowerPointDeck.uploading
    /// Saves the deck; true when it is saved afterwards.
    var save: (String) -> Bool = { PowerPointDeck.save($0, reason: "SlidesSeen") }
    var needsSave: (String) -> Bool = PowerPointDeck.needsSave
    var spotlightImport: (String) -> Void = SlidesSeenRecorder.spotlightImport
}

/// 📑 Slides seen: every slide shown ≥ 7 s goes into a day log, with a copy of the
/// deck as it was on disk when shown, so a summary can later export exactly that
/// slide (by `slide ID`, not position) as a PDF page with its links.
///
/// Everything lives in PowerPoint's own sandbox container: PowerPoint opens and
/// writes files there without its "Grant File Access" dialog, which it raises for
/// any other path it is asked to open or write by script (measured 2026-10-29).
final class SlidesSeenRecorder {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.microsoft.Powerpoint/Data/Documents/slides-seen")
    /// `.noindex` keeps Spotlight out by name alone. Indexed, the ~350 copies crowded every
    /// real deck out of the ⌘Space results (2026-11-13) — and a Search Privacy entry is a
    /// setting an OS update can reset, a folder name is not.
    static let decksDirName = "decks.noindex"
    /// The day logs are tiny and are the record of what was shown: 30 days.
    static let retentionDays = 30
    /// A deck copy is ~16 MB and only serves the summary of the day it was shown
    /// (350 copies, 5.2 GB after two weeks at 30 days): 5 days since it was **last shown**
    /// (Victor, 2026-11-14 — a summary is sometimes written a few days late). Counted from the copy's own mtime, which `snapshot` sets to now —
    /// a copy inherits the deck's mtime, so an untouched deck would be pruned the day it was shown.
    static let copyRetentionDays = 5

    /// `slide_seen` messages for the training-assistant daemon (sent on this recorder's queue).
    var onEvent: (([String: Any]) -> Void)?
    private var policy = SlidesSeenPolicy()
    private let queue = DispatchQueue(label: "ro.victorrentea.slides-seen", qos: .utility)
    /// path → (size, mtime, snapshot file name): skip re-hashing an unchanged deck.
    private var lastSnapshot: [String: (Int, Date, String)] = [:]
    /// The snapshot taken when the current span qualified, written with it on close.
    private var pendingSnapshot: String?
    /// Slides left and not yet reported as `closed`, oldest first: their deck has unsaved
    /// edits and the save waits for his hands to pause (`SlidesSeenCloseSave.step`).
    private var leftSlides: [(span: SlideSpan, snapshot: String?, since: Date)] = []
    /// Slides reported as `closed` while their deck still had unsaved edits (hands that
    /// never paused, a slide show, a refused save), by deck path: reported again at the
    /// first probe that shows the deck saved, so the daemon gets the form that was shown.
    private var reportedUnsaved: [String: [SlideSpan]] = [:]
    private var reindex = SpotlightReindexPolicy()
    private var lastPrune = Date()
    private let world: SlidesSeenWorld

    init(world: SlidesSeenWorld = SlidesSeenWorld()) {
        self.world = world
        queue.async {
            Self.migrateDecksDir(root: world.root)
            Self.prune(root: world.root)
        }
    }

    /// Waits for every probe consumed so far (tests).
    func drain() { queue.sync {} }

    /// The copies lived in `decks/` until 2026-11-13: move the folder once, whole.
    static func migrateDecksDir(root: URL = SlidesSeenRecorder.root) {
        let fm = FileManager.default
        let old = root.appendingPathComponent("decks")
        let new = root.appendingPathComponent(decksDirName)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do { try fm.moveItem(at: old, to: new) } catch {
            overlayError("SlidesSeen: could not rename decks → \(decksDirName): \(error.localizedDescription)")
        }
    }

    static func spotlightImport(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        p.arguments = [path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func consume(_ sample: PowerPointSample) {
        queue.async { [self] in
            if let path = reindex.consume(sample) { world.spotlightImport(path) }
            reportAgainOnceSaved(sample)
            for action in policy.consume(sample) {
                switch action {
                case .qualified(let span):
                    pendingSnapshot = nil
                    // A deck never saved has no file to copy, and must not be saved behind his back.
                    if let path = span.path, PowerPointDeck.hasFile(path) {
                        // Unsaved edits are not on disk, and the copy is taken from disk: save first.
                        // Victor asked for it (2026-10-29) — but not under his hands: a slide he is
                        // editing at its 7th second is saved when he leaves it (`reportLeftSlides`).
                        if SlidesSeenCloseSave.saveWhenQualified(sample, idle: world.idle(),
                                                                 uploading: world.uploading(path)) {
                            _ = world.save(path)
                        }
                        pendingSnapshot = snapshot(path)
                    }
                    send(.qualified, span)
                case .closed(let span):
                    leftSlides.append((span, pendingSnapshot, sample.at))
                    pendingSnapshot = nil
                }
            }
            reportLeftSlides(sample)
        }
    }

    /// Edits made on a slide after its 7 s save go to disk before the daemon reads it — once
    /// his hands have paused. In the order the slides were left; one save covers them all.
    private func reportLeftSlides(_ sample: PowerPointSample) {
        /// Decks dealt with in this pass → whether edits of theirs are still not on disk.
        var unsavedAfter: [String: Bool] = [:]
        while let left = leftSlides.first {
            let path = left.span.path ?? ""
            let unsaved: Bool
            if let known = unsavedAfter[path] {
                unsaved = known
            } else {
                // His hands are asked about again for every slide: a save takes a second,
                // sometimes thirty, and he may be typing again by the next one.
                let step = SlidesSeenCloseSave.step(
                    span: left.span, now: sample, waited: sample.at.timeIntervalSince(left.since),
                    idle: world.idle(), uploading: world.uploading(path))
                switch step {
                case .wait: return
                case .send: unsaved = SlidesSeenCloseSave.leftUnsaved(span: left.span, now: sample)
                case .saveThenSend(let path): unsaved = !world.save(path)
                case .askThenSend(let path): unsaved = world.needsSave(path) && !world.save(path)
                }
                unsavedAfter[path] = unsaved
            }
            // The copy named in the day log is the deck as it is on disk now, after the save:
            // the one taken at 7 s lacks what he typed since, and all of it when that save was
            // skipped for his busy hands. Unchanged size and mtime → the same copy, no re-hash.
            let shown = PowerPointDeck.hasFile(path) ? snapshot(path) : nil
            append(left.span, snapshot: shown ?? left.snapshot)
            send(.closed, left.span)
            if unsaved { rememberUnsaved(left.span, path) }
            leftSlides.removeFirst()
        }
    }

    private func rememberUnsaved(_ span: SlideSpan, _ path: String) {
        var spans = reportedUnsaved[path, default: []]
        spans.removeAll { $0.slideID == span.slideID }
        spans.append(span)
        reportedUnsaved[path] = spans
    }

    /// The daemon read those slides before their edits reached the disk: tell it again now
    /// that they have (it records a slide in the same form twice as nothing). PowerPoint gone
    /// may have saved on its way out, and nothing more will be known: all of them go again.
    private func reportAgainOnceSaved(_ sample: PowerPointSample) {
        guard !reportedUnsaved.isEmpty else { return }
        let ready: [String]
        if sample.deck.isEmpty {
            ready = Array(reportedUnsaved.keys)
        } else if let path = sample.path, sample.saved, reportedUnsaved[path] != nil {
            ready = [path]
        } else {
            return
        }
        for path in ready.sorted() {
            for span in reportedUnsaved.removeValue(forKey: path) ?? [] { send(.closed, span) }
        }
    }

    private func send(_ phase: SlidesSeenEvent.Phase, _ span: SlideSpan) {
        guard let payload = SlidesSeenEvent.payload(phase, span: span, at: span.end) else { return }
        onEvent?(payload)
    }

    /// Content-addressed copy: one file per distinct version of a deck.
    private func snapshot(_ path: String) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        // The app runs for days: prune here too, not only at launch.
        if Date().timeIntervalSince(lastPrune) > 3600 { Self.prune(root: world.root); lastPrune = Date() }
        let decks = world.root.appendingPathComponent(Self.decksDirName)
        if let last = lastSnapshot[path], last.0 == size, last.1 == mtime,
           fm.fileExists(atPath: decks.appendingPathComponent(last.2).path) {
            Self.markShown(decks.appendingPathComponent(last.2))
            return last.2
        }
        guard let sha = Self.sha256(path) else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension.isEmpty ? "pptx" : URL(fileURLWithPath: path).pathExtension
        let name = "\(sha.prefix(16)).\(ext)"
        let dest = decks.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: decks, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(atPath: path, toPath: dest.path) }
            Self.markShown(dest)
        } catch {
            overlayError("SlidesSeen: snapshot of \(path) failed: \(error.localizedDescription)")
            return nil
        }
        lastSnapshot[path] = (size, mtime, name)
        return name
    }

    private func append(_ span: SlideSpan, snapshot: String?) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        var entry: [String: Any] = [
            "start": iso.string(from: span.start), "end": iso.string(from: span.end),
            "seconds": Int(span.end.timeIntervalSince(span.start).rounded()),
            "deck": span.deck, "slide": span.slide, "slide_id": span.slideID,
            "presenting": span.presenting,
        ]
        if let p = span.path { entry["path"] = p }
        if let s = snapshot { entry["snapshot"] = s }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let logDir = world.root.appendingPathComponent("log")
        let file = logDir.appendingPathComponent("\(day.string(from: span.start)).jsonl")
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: file)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data + Data("\n".utf8))
        } catch {
            overlayError("SlidesSeen: log write failed: \(error.localizedDescription)")
        }
    }

    static func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Retention counts from when a copy was last shown, not from when the deck was last edited.
    static func markShown(_ copy: URL, at now: Date = Date()) {
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: copy.path)
    }

    /// Day logs older than `retentionDays` go; deck copies and export scratch after `copyRetentionDays`.
    static func prune(root: URL = SlidesSeenRecorder.root, now: Date = Date()) {
        let fm = FileManager.default
        for (sub, days) in [("log", retentionDays), (decksDirName, copyRetentionDays), ("work", copyRetentionDays)] {
            let cutoff = now.addingTimeInterval(-Double(days) * 86400)
            let dir = root.appendingPathComponent(sub)
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let m, m < cutoff { try? fm.removeItem(at: f) }
            }
        }
    }
}
