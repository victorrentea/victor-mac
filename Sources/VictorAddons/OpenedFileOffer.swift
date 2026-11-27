import Cocoa

/// 📄 A file opened in VS Code / IntelliJ reaches the session's opened-files
/// list only through **an auto-send pill**, and only when it will be listed
/// (2026-11-27, Victor: *"de ce a apărut în overlay dacă nu a ajuns în Open
/// Files? … să apară jos cu send sau dismiss, cu send-ul automat, doar dacă se
/// duce în Training Assistant, altfel nu"*).
///
/// Before, every editor report was pushed to the daemon *and* flashed as
/// `📄 name` — so a file the daemon then dropped (a private repo, a repo GitHub
/// was rate-limiting, no session) still had its name on the projected screen.
/// Now, per file (canonical repo + path, `OpenedFileBannerLog.identity`):
///
/// 1. **Ask first** — `git_file_check` to the daemon, which answers with the
///    same gates it records by (`files_md.would_record`). No answer within
///    `checkTimeout`, or "not listed" → nothing on screen, nothing sent.
/// 2. **Offer** — the editor's logo + file name on the hoverable pill, counting
///    down `countdown`: left alone it **sends** (`git_file_opened`, rises);
///    hovered or clicked it is **dismissed** (sinks) and never sent.
/// 3. **Remember the verdict** for `OpenedFileBannerLog.repeatAfter`: a file
///    sent before is re-pushed silently on every later open (the daemon
///    refreshes its time and branch, as it always did); a dismissed one never.
final class OpenedFileOffer {
    enum Verdict: String { case sent, dismissed }

    static let checkTimeout: TimeInterval = 5
    static let countdown: TimeInterval = 6
    private static let defaultsKey = "OpenedFileOffer.verdicts.v1"

    private let ask: (_ id: String, _ url: String, _ file: String) -> Void
    private let push: (_ url: String, _ branch: String, _ file: String) -> Void
    private let screens: () -> [NSScreen]
    private struct Pending { let identity: String; let url: String; let branch: String; let file: String; let icon: NSImage? }
    /// Checks awaiting the daemon, by request id. Main thread.
    private var pending: [String: Pending] = [:]
    /// Identities asked about or on a pill right now: a second report waits it out.
    private var inFlight: Set<String> = []
    private var banners: [BottomLeftBanner] = []

    init(ask: @escaping (String, String, String) -> Void,
         push: @escaping (String, String, String) -> Void,
         screens: @escaping () -> [NSScreen] = { NSScreen.pillScreens }) {
        self.ask = ask
        self.push = push
        self.screens = screens
    }

    // MARK: - Pure

    enum Action: Equatable { case pushSilently, ask, ignore }

    /// What one editor report leads to, given the stored verdicts.
    static func action(identity: String?, sessionActive: Bool, inFlight: Bool,
                       verdict: Verdict?) -> Action {
        guard sessionActive, identity != nil, !inFlight else { return .ignore }
        switch verdict {
        case .sent: return .pushSilently
        case .dismissed: return .ignore
        case nil: return .ask
        }
    }

    // MARK: - Flow (main thread)

    func fileOpened(url: String, branch: String, file: String, sessionActive: Bool, icon: NSImage?) {
        let identity = OpenedFileBannerLog.identity(url: url, file: file)
        switch Self.action(identity: identity, sessionActive: sessionActive,
                           inFlight: identity.map(inFlight.contains) ?? false,
                           verdict: identity.flatMap { Self.verdict(for: $0) }) {
        case .ignore: return
        case .pushSilently: push(url, branch, file)
        case .ask:
            guard let identity else { return }
            let id = UUID().uuidString
            pending[id] = Pending(identity: identity, url: url, branch: branch, file: file, icon: icon)
            inFlight.insert(identity)
            ask(id, url, file)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkTimeout) { [weak self] in
                guard let self, let p = self.pending.removeValue(forKey: id) else { return }
                self.inFlight.remove(p.identity)
                overlayInfo("📄 No answer from the daemon about \(p.file) — not offered")
            }
        }
    }

    /// The daemon's `git_file_check_result`.
    func checkAnswered(id: String, listed: Bool) {
        guard let p = pending.removeValue(forKey: id) else { return }
        guard listed else {
            inFlight.remove(p.identity)
            overlayInfo("📄 \(p.file) would not be listed — not offered")
            return
        }
        offer(p)
    }

    private func offer(_ p: Pending) {
        let banner = BottomLeftBanner(screensProvider: screens, hoverable: true)
        banners.removeAll { !$0.isVisible }
        banners.append(banner)
        var decided = false
        let decide: (Verdict) -> Void = { [weak self, weak banner] verdict in
            guard !decided else { return }
            decided = true
            Self.store(verdict, for: p.identity)
            self?.inFlight.remove(p.identity)
            if verdict == .sent {
                self?.push(p.url, p.branch, p.file)
                banner?.dismissRisingFade()
            } else {
                banner?.dismissSinking()
            }
        }
        banner.onHover = { decide(.dismissed) }
        banner.onHoverCountdownExpired = { decide(.sent) }
        banner.icon = p.icon
        banner.show(text: EditorLogo.bannerText(file: p.file, hasLogo: p.icon != nil),
                    hoverCountdown: Self.countdown, hoverNudge: .down,
                    autoAction: .send, clickAction: .cancel)
    }

    // MARK: - Verdicts, persisted so a restart does not re-offer or leak a dismissed file

    static func verdict(for identity: String, now: Date = Date()) -> Verdict? {
        guard let entry = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]])?[identity],
              let at = entry["at"] as? Double, now.timeIntervalSince1970 - at < OpenedFileBannerLog.repeatAfter,
              let raw = entry["v"] as? String else { return nil }
        return Verdict(rawValue: raw)
    }

    static func store(_ verdict: Verdict, for identity: String, now: Date = Date()) {
        let t = now.timeIntervalSince1970
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
        all = all.filter { t - (($0.value["at"] as? Double) ?? 0) < OpenedFileBannerLog.repeatAfter }
        all[identity] = ["v": verdict.rawValue, "at": t]
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }
}
