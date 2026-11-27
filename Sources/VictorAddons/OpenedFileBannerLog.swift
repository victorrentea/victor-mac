import Foundation

/// The identity of an opened file — canonical repo + repo-relative path, the
/// pair the daemon upserts on — and how long a verdict about it lasts.
///
/// Since 2026-11-27 the banner and the push are both decided by
/// `OpenedFileOffer` (ask the daemon, then an auto-send pill); it keys its
/// verdicts on `identity(url:file:)` and expires them after `repeatAfter`.
/// `decide`/`shouldAnnounce` are the earlier flash-once log, kept for their
/// tests of the identity rules.
///
/// ## One identity for a duplicate
///
/// The daemon's key is the authoritative one, and `identity(url:file:)` mirrors
/// it. Keying on the path alone would be wrong: `file` is *repo-relative*, so
/// `pom.xml` — or `README.md`, or `src/main/java/App.java` — is a different file
/// in every repo opened during a workshop, and a path-only key would mute all
/// but the first of them.
enum OpenedFileBannerLog {
    /// How long a file stays "already announced". Longer than a training day,
    /// so a file opened at 9:00 never flashes again at 16:00; short enough that
    /// tomorrow's session starts with a clean slate.
    static let repeatAfter: TimeInterval = 20 * 3600
    /// Bound on the stored log. Far above a day of editing, and pruning keeps
    /// the newest entries — the ones that would actually be re-opened.
    static let maxEntries = 500

    private static let defaultsKey = "OpenedFileBannerLog.v1"

    /// What the editors send when a project is open but no file is selected.
    /// The daemon drops it (`files_md._ADDON_NO_FILE_SENTINEL`); so must the
    /// banner, rather than flashing a literal `📄 (none)`.
    static let noFileSentinel = "(none)"

    /// The identity a duplicate is judged on: canonical repo + repo-relative
    /// path, the same pair `files_md` upserts on. `nil` when the event names no
    /// file at all — nothing to announce and nothing to remember.
    ///
    /// Canonicalisation follows `files_md._canonical_repo_url`: host lowercased,
    /// `.git` and trailing slashes gone (that much `GitRemote.https` already
    /// does), and everything past `owner/repo` dropped, so a remote written
    /// three ways is one repo. A non-GitHub host keeps its own shape — the
    /// daemon refuses to list those, but the banner is local awareness and has
    /// no reason to inherit that rule.
    static func identity(url: String, file: String) -> String? {
        let path = file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path != noFileSentinel else { return nil }

        var repo = GitRemote.https(url).trimmingCharacters(in: .whitespacesAndNewlines)
        while repo.hasSuffix("/") { repo.removeLast() }
        if let parsed = URL(string: repo), let host = parsed.host {
            let segments = parsed.path.split(separator: "/").map(String.init)
            if segments.count >= 2 {
                repo = "https://\(host.lowercased())/\(segments[0])/\(segments[1])"
            } else {
                repo = "https://\(host.lowercased())\(parsed.path)"
            }
        }
        return "\(repo)|\(path)"
    }

    /// Pure decision, plus the log to store afterwards. `seen` maps an
    /// `identity` to the `timeIntervalSinceReferenceDate` of its last banner.
    ///
    /// A stamp in the *future* (a Mac back from sleep with a bad clock) counts
    /// as expired rather than as a permanent mute: one banner, and the entry is
    /// rewritten with a sane `now`.
    static func decide(seen: [String: Double],
                       identity: String?,
                       now: Double,
                       repeatAfter: TimeInterval = repeatAfter,
                       maxEntries: Int = maxEntries) -> (announce: Bool, seen: [String: Double]) {
        guard let key = identity, !key.isEmpty else { return (false, seen) }

        let last = seen[key]
        let announce = last.map { now - $0 >= repeatAfter || $0 > now } ?? true

        var updated = seen
        updated[key] = now
        // Drop anything past the horizon first — it can never mute again — and
        // only then trim by count, oldest going first.
        updated = updated.filter { now - $0.value < repeatAfter || $0.value > now }
        if updated.count > maxEntries {
            let keep = updated.sorted { $0.value > $1.value }.prefix(maxEntries)
            updated = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return (announce, updated)
    }

    /// `true` the first time this file is seen (and again once `repeatAfter`
    /// has passed); records the visit either way. Called from the HTTP
    /// server's queue, which `UserDefaults` handles fine on its own.
    static func shouldAnnounce(url: String, file: String, now: Date = Date()) -> Bool {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        let (announce, updated) = decide(seen: stored, identity: identity(url: url, file: file),
                                         now: now.timeIntervalSinceReferenceDate)
        UserDefaults.standard.set(updated, forKey: defaultsKey)
        return announce
    }

    /// Forget everything — the escape hatch for "show me these again".
    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
