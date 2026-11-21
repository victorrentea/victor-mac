import Cocoa

/// 🌿 "petclinic is still on main": the rules, pure. `PetclinicBranchWarning`
/// feeds it the repo's HEAD file, the session flag and the clock.
///
/// Asked for on 2026-11-19 (Victor: *"remind me to create a new branch for the
/// current workshop"*): every workshop's live coding goes on its own branch of
/// `~/workspace/petclinic`, and starting one on `main` means untangling it later.
enum PetclinicBranchPolicy {
    /// The branches that mean "no workshop branch yet".
    static let trunks: Set<String> = ["main", "master"]

    /// `.git/HEAD` → the checked-out branch; nil for a detached HEAD or garbage.
    static func branch(fromHEAD head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else { return nil }
        let name = String(line.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }

    /// The pill is up while a training session runs, petclinic sits on a trunk
    /// branch and Victor has not waved it away today.
    static func shouldWarn(sessionActive: Bool, branch: String?, dismissedDay: String?, today: String) -> Bool {
        guard sessionActive, let branch, trunks.contains(branch) else { return false }
        return dismissedDay != today
    }

    static func text(branch: String) -> String {
        "🌿 petclinic is on \(branch) — create this workshop's branch"
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// 🌿 A bottom-left pill that stays while a training session is active and
/// `~/workspace/petclinic` is checked out on `main`. It goes away by itself the
/// moment another branch is checked out (HEAD is re-read every few seconds),
/// and comes back if `main` is checked out again during the session.
///
/// Click-only like the ✈️ check-in pill: a click (or right-click) dismisses it
/// **for the rest of the day** — a workshop where the code stays on `main` on
/// purpose should not nag after every redeploy. The dismissal is in
/// `UserDefaults` (`petclinicBranch.dismissedDay`) so a restart respects it.
final class PetclinicBranchWarning {
    /// Red since 2026-11-22 (Victor: purple read as decoration, not as a warning).
    static let color = NSColor.systemRed.withAlphaComponent(0.9)
    static let fontSize: CGFloat = 24
    static let checkEvery: TimeInterval = 5
    private static let dismissedKey = "petclinicBranch.dismissedDay"

    private let headURL: URL
    private let screensProvider: () -> [NSScreen]
    private let defaults: UserDefaults
    private let now: () -> Date
    private var banner: BottomLeftBanner?
    private var shownText: String?
    private var timer: Timer?
    private(set) var sessionActive = false
    /// `/test/petclinic-branch/simulate`: show it off the retina regardless of
    /// session and branch, until `/clear`.
    private var simulatedScreens: (() -> [NSScreen])?

    init(repo: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("workspace/petclinic"),
         screensProvider: @escaping () -> [NSScreen] = { NSScreen.pillScreens },
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.headURL = repo.appendingPathComponent(".git/HEAD")
        self.screensProvider = screensProvider
        self.defaults = defaults
        self.now = now
    }

    var currentBranch: String? {
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        return PetclinicBranchPolicy.branch(fromHEAD: head)
    }

    private var dismissedDay: String? { defaults.string(forKey: Self.dismissedKey) }

    var shouldWarn: Bool {
        PetclinicBranchPolicy.shouldWarn(sessionActive: sessionActive, branch: currentBranch,
                                         dismissedDay: dismissedDay,
                                         today: PetclinicBranchPolicy.dayKey(now()))
    }

    /// From the training session's start/end (`AppDelegate.handleSession*`).
    func setSessionActive(_ active: Bool) {
        sessionActive = active
        if active, timer == nil {
            let t = Timer(timeInterval: Self.checkEvery, repeats: true) { [weak self] _ in self?.evaluate() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !active {
            timer?.invalidate()
            timer = nil
        }
        evaluate()
    }

    func evaluate() {
        if simulatedScreens != nil { return }
        if shouldWarn, let branch = currentBranch {
            present(PetclinicBranchPolicy.text(branch: branch), screens: screensProvider)
        } else {
            takeDown()
        }
    }

    private func present(_ text: String, screens: @escaping () -> [NSScreen]) {
        if let b = banner, b.isVisible {
            if shownText != text { b.updateText(text); shownText = text }
            return
        }
        overlayInfo("🌿 petclinic branch warning up: \(text)")
        let b = BottomLeftBanner(screensProvider: screens, hoverable: true)
        banner = b
        shownText = text
        b.clickOnly = true
        b.onHover = { [weak self] in self?.dismissForToday() }
        // Right-click is the pill's other exit; here both mean "not today".
        b.onHoverCountdownExpired = { [weak self] in self?.dismissForToday() }
        b.show(text: text, backgroundColor: Self.color,
               font: NSFont.boldSystemFont(ofSize: Self.fontSize),
               // The click only waves it away for today — nothing opens, so the
               // button says so (it read "Open" until 2026-11-22).
               clickAction: .dismiss)
    }

    private func takeDown() {
        guard let b = banner else { return }
        overlayInfo("🌿 petclinic branch warning down (branch: \(currentBranch ?? "?"))")
        b.dismissSinking()
        banner = nil
        shownText = nil
    }

    func dismissForToday() {
        if simulatedScreens != nil { clearSimulation(); return }
        defaults.set(PetclinicBranchPolicy.dayKey(now()), forKey: Self.dismissedKey)
        overlayInfo("🌿 petclinic branch warning dismissed for today")
        takeDown()
    }

    func simulate(screens: @escaping () -> [NSScreen]) {
        takeDown()
        simulatedScreens = screens
        present(PetclinicBranchPolicy.text(branch: "main"), screens: screens)
    }

    /// Ends a simulation and forgets today's dismissal, then re-evaluates.
    func clearSimulation() {
        simulatedScreens = nil
        takeDown()
        evaluate()
    }

    func resetDismissal() {
        defaults.removeObject(forKey: Self.dismissedKey)
        evaluate()
    }

    func stateJSON() -> String {
        let branch = currentBranch.map { CheckInAlarm.quote($0) } ?? "null"
        let dismissed = dismissedDay.map { CheckInAlarm.quote($0) } ?? "null"
        return "{\"sessionActive\":\(sessionActive),\"branch\":\(branch),\"dismissedDay\":\(dismissed),"
            + "\"shouldWarn\":\(shouldWarn),\"visible\":\(banner?.isVisible ?? false),"
            + "\"simulated\":\(simulatedScreens != nil)}"
    }
}
