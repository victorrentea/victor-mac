import AppKit
import Foundation

/// **🪄 Victor Mic** — the noise-cancelled microphone, run by its own app
/// ([`victor-mic`](../../../victor-mic), port **55128**) since 2026-11-20.
///
/// Why another process: the cleaning has to keep running while *this* app is
/// rebuilt and restarted ten times a day, and a call must not lose its voice
/// with every deploy. The "Victor Mic" device itself is a HAL driver living
/// in `coreaudiod`, so it never disappears either way; the Victor Mic app only
/// writes the cleaned voice into it, and only while some app (Zoom, Teams,
/// Wispr) is reading it.
///
/// **What it cleans is the system default input**, which `SystemMicKeeper`
/// already keeps on the 🎙️ menu's pick (or the XLR ▸ DJI ▸ … ladder) — so the
/// rows above this one choose Victor Mic's source too, with no protocol of
/// their own. This file only shows its state in the 🎙️ menu and flips the
/// cleaning on/off (`GET /clean/on|off`), an A/B against the raw microphone.
final class VictorMicLink {
    static let shared = VictorMicLink()
    static let base = URL(string: "http://127.0.0.1:55128")!

    struct State: Equatable {
        var driver = false
        var reading = false
        var running = false
        var clean = true
        var source: String?
        var error: String?
    }

    /// nil = the app did not answer.
    private(set) var state: State?
    private var timer: Timer?

    private init() {}

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh(then: (() -> Void)? = nil) {
        fetch("/state", then: then)
    }

    func setClean(_ on: Bool, then: (() -> Void)? = nil) {
        fetch(on ? "/clean/on" : "/clean/off", then: then)
    }

    private func fetch(_ path: String, then: (() -> Void)?) {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let parsed = data.flatMap(Self.parse)
            DispatchQueue.main.async {
                self?.state = parsed
                then?()
            }
        }.resume()
    }

    static func parse(_ data: Data) -> State? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return State(driver: o["driver"] as? Bool ?? false,
                     reading: o["reading"] as? Bool ?? false,
                     running: o["running"] as? Bool ?? false,
                     clean: o["clean"] as? Bool ?? true,
                     source: o["source"] as? String,
                     error: o["error"] as? String)
    }

    /// The 🎙️ menu row: its title, whether it can be clicked, and its tick.
    /// Pure, so every state reads right without a running app.
    static func row(_ s: State?, glyph: (String) -> String?) -> (title: String, enabled: Bool, ticked: Bool) {
        guard let s else { return ("🪄 Victor Mic — app not running", false, false) }
        guard s.driver else { return ("🪄 Victor Mic — driver not installed", false, false) }
        let from = s.source.map { name in glyph(name).map { "\($0) \(name)" } ?? name } ?? "no microphone"
        let status: String
        if let error = s.error, s.running || s.source == nil {
            status = error
        } else if s.running {
            status = s.clean ? "cleaning \(from)" : "raw \(from), not cleaned"
        } else {
            status = "idle, no app listening"
        }
        return ("🪄 Victor Mic — \(status)", true, s.clean)
    }
}
