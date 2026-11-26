import CoreWLAN
import CryptoKit
import Foundation
import SystemConfiguration

/// What the phone is told about the running break.
struct PhoneBreakState: Equatable {
    /// When this break began, in ms (`BreakTimerController.breakStartedAt`, persisted):
    /// a re-click to another length keeps it, a new break gets a new one.
    let breakId: Int64
    /// The absolute wall-clock end, in ms. While paused it is `now + left` and keeps sliding.
    let endMs: Int64
    let paused: Bool
    let leftMs: Int64
}

/// 📱 Pure half of `BreakPhoneMirror`: what goes to the phone, when, and which
/// requests from it are believed. No sockets, so a test can pin it.
enum BreakPhonePolicy {
    /// The phone's one button (Victor, 2026-11-26: "+5", even though the menu has other steps).
    static let extendSeconds = 300
    /// While a break runs, the state goes again this often: the Railway box holds only the
    /// newest envelope, and a clip put there after ours would hide it from the phone.
    static let refreshEvery: TimeInterval = 180
    /// A send that reached the phone by no way is retried this often.
    static let retryEvery: TimeInterval = 10
    /// An extend older than this is a replay (two clocks compared, so generous).
    static let maxAskAgeMs: Int64 = 120_000
    /// The watch counts whole seconds off a timer, so `now + remaining` wobbles by one.
    static let tolerance: Int64 = 2_500
    /// `from` of the Mac's break envelopes in the phone's box; a phone build older than
    /// this feature drops any `from` it does not know (`ClipSync.kt`).
    static let fromMac = "mac-break"
    /// `from` of the phone's requests in the Mac's box. victor-net's `ClipSync` believes
    /// only `"phone"`, so it ignores these without pasting anything.
    static let fromPhone = "phone-break"

    static func state(remaining: Int, paused: Bool, breakStartedAt: Date?, now: Date) -> PhoneBreakState {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let left = Int64(max(0, remaining)) * 1000
        let id = breakStartedAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        return PhoneBreakState(breakId: id, endMs: nowMs + left, paused: paused, leftMs: left)
    }

    /// Whether the phone needs to hear about the move from `old` to `new`.
    static func changed(_ old: PhoneBreakState?, _ new: PhoneBreakState?) -> Bool {
        guard let old, let new else { return (old == nil) != (new == nil) }
        if old.breakId != new.breakId || old.paused != new.paused { return true }
        if new.paused { return abs(new.leftMs - old.leftMs) > tolerance }
        // At zero the watch gongs for ~18 s with `remaining` 0: its end does not move.
        if new.leftMs == 0 { return false }
        return abs(new.endMs - old.endMs) > tolerance
    }

    /// The break left the screen: did it run out (it was at zero, not paused) or was it closed?
    static func expired(last: PhoneBreakState?) -> Bool {
        guard let last else { return false }
        return !last.paused && last.leftMs <= 1_000
    }

    /// The plaintext of one envelope for the phone. `"break": null` = no break any more.
    static func envelope(_ s: PhoneBreakState?, expired: Bool, id: String, nowMs: Int64) -> [String: Any] {
        var o: [String: Any] = ["id": id, "ts": nowMs, "from": fromMac, "text": "", "expired": expired]
        if let s {
            o["break"] = ["id": s.breakId, "endMs": s.endMs, "paused": s.paused, "leftMs": s.leftMs,
                          "extendS": extendSeconds] as [String: Any]
        } else {
            o["break"] = NSNull()
        }
        return o
    }

    enum Ask: Equatable {
        case extend(seconds: Int)
        /// Not for us at all (a clip, victor-net's business): no log line.
        case ignore
        case refused(String)
    }

    /// One opened envelope from the phone. Only an extend of the break on screen now,
    /// fresh and never seen, is believed; the seal itself proved it came from the phone.
    static func ask(_ o: [String: Any], currentBreakId: Int64?, seen: Set<String>, nowMs: Int64) -> Ask {
        guard o["from"] as? String == fromPhone else { return .ignore }
        guard let id = o["id"] as? String, !id.isEmpty else { return .refused("no id") }
        if seen.contains(id) { return .ignore }   // the same request by its other way
        guard let ts = (o["ts"] as? NSNumber)?.int64Value, abs(nowMs - ts) < maxAskAgeMs else {
            return .refused("stale")
        }
        guard o["action"] as? String == "extend" else { return .refused("unknown action") }
        guard let current = currentBreakId else { return .refused("no break running") }
        guard (o["breakId"] as? NSNumber)?.int64Value == current else { return .refused("another break") }
        return .extend(seconds: extendSeconds)
    }
}

/// AES-256-GCM as victor-net's `ClipCrypto` and the phone's `ClipSync.kt` do it:
/// nonce + ciphertext + tag, base64url without padding, with `CLIP_KEY`.
enum PhoneSeal {
    static func key(hex: String) -> SymmetricKey? {
        guard hex.count == 64 else { return nil }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<next], radix: 16) else { return nil }
            bytes.append(b)
            i = next
        }
        return SymmetricKey(data: bytes)
    }

    static func seal(_ object: [String: Any], key: SymmetricKey) -> String? {
        guard let plain = try? JSONSerialization.data(withJSONObject: object),
              let combined = try? AES.GCM.seal(plain, using: key).combined else { return nil }
        return combined.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func open(_ sealed: String, key: SymmetricKey) -> [String: Any]? {
        var b64 = sealed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }
}

/// 📱 **The break's time left, on the phone** (2026-11-26, Victor: *"când pornesc pauza din
/// Victor Mac, vreau să văd pe telefon timpul rămas … și un buton să prelungesc pauza"*).
///
/// Polled once a second, like `BreakTimeMirror`: whatever moved the watch (menu, ☕, +min,
/// ⏸, a redeploy's resume, ✕, expiry) shows up as a new state, and only a real change
/// is sent — the absolute end, so the phone's notification ticks on its own.
///
/// **Mac → phone**: the envelope is sealed with victor-net's `CLIP_KEY` and goes to the
/// phone's box on Railway (`/api/clip/phone`), which the phone long-polls on any network
/// it has: the one way that works on the same Wi-Fi, on the hotspot and with the phone on
/// mobile data while this Mac sits on venue Wi-Fi. On the phone's hotspot it also goes
/// straight to `http://<gateway>:55126/clip`, so a Railway outage does not matter there.
/// Bluetooth is left out: the RFCOMM channel is victor-net's, one at a time.
///
/// **Phone → Mac** (the notification's +5): sealed the same way, into this Mac's box
/// (`/api/clip/mac`, long-polled here only while a break runs) and, when the phone has
/// seen this Mac on a LAN, to `/break/phone?c=…` on 55123. The seal is the auth: only
/// the two ends hold the key.
///
/// The config is victor-net's (`~/.victor-net/config.env`: `RELAY_URL`, `RELAY_TOKEN`,
/// `CLIP_KEY`, `HOTSPOT_SSID`), because it is that app's link to the same phone.
final class BreakPhoneMirror {
    typealias Running = (remaining: Int, paused: Bool, startedAt: Date?)

    private let breakState: () -> Running?
    private let onExtend: (Int) -> Void
    private let config: [String: String]
    private let key: SymmetricKey?
    private var relayURL: String { config["RELAY_URL"] ?? "" }
    private var relayToken: String { config["RELAY_TOKEN"] ?? "" }

    private var timer: Timer?
    /// What the phone was last told (nil = no break), and when.
    private var told: PhoneBreakState?
    private var toldAt: Date?
    private var everTold = false
    /// What the watch said on the previous tick: whether a break that vanished ran out is
    /// read here, not off `told`, which may be a minute old.
    private var lastSeen: PhoneBreakState?
    /// The "over" of a send still being retried.
    private var retryExpired = false
    private var retryAt: Date?
    private var lastSend: (at: Date, via: String, expired: Bool)?
    private var lastError: String?
    private var lastAsk: (at: Date, verdict: String)?
    private var seen: [String] = []
    private var pollAfter = -1
    /// The first answer of a run only says where the box stands (an empty box answers our own
    /// `after` back, so `pollAfter` alone cannot tell).
    private var primed = false
    private var polling = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(breakState: @escaping () -> Running?, onExtend: @escaping (Int) -> Void) {
        self.breakState = breakState
        self.onExtend = onExtend
        self.config = Self.loadConfig()
        self.key = PhoneSeal.key(hex: config["CLIP_KEY"] ?? "")
    }

    func start() {
        guard key != nil, !relayURL.isEmpty, !relayToken.isEmpty else {
            return overlayInfo("📱 break → phone off: no CLIP_KEY / RELAY_URL / RELAY_TOKEN in ~/.victor-net/config.env")
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func current(now: Date) -> PhoneBreakState? {
        breakState().map { BreakPhonePolicy.state(remaining: $0.remaining, paused: $0.paused,
                                                  breakStartedAt: $0.startedAt, now: now) }
    }

    private func tick() {
        let now = Date()
        let state = current(now: now)
        let previous = lastSeen
        lastSeen = state
        if state != nil, !polling { poll() }
        // At launch with no break there is nothing to clear: a phone with a stale
        // countdown still gets the "none" on the first real change.
        if !everTold, state == nil { return }
        let due = !everTold
            || BreakPhonePolicy.changed(told, state)
            || (state != nil && toldAt.map { now.timeIntervalSince($0) >= BreakPhonePolicy.refreshEvery } ?? true)
            || (retryAt.map { now >= $0 } ?? false)
        guard due else { return }
        let expired = state == nil && (BreakPhonePolicy.expired(last: previous) || (retryAt != nil && retryExpired))
        send(state, expired: expired)
    }

    private func send(_ state: PhoneBreakState?, expired: Bool) {
        guard let key else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let plain = BreakPhonePolicy.envelope(state, expired: expired, id: UUID().uuidString, nowMs: nowMs)
        guard let sealed = PhoneSeal.seal(plain, key: key) else { return }
        told = state
        toldAt = Date()
        everTold = true
        retryAt = nil
        let what = state.map { $0.paused ? "paused, \($0.leftMs / 1000)s left" : "ends in \($0.leftMs / 1000)s" }
            ?? (expired ? "over" : "cancelled")
        var ways: [String] = []
        var pending = 0
        var anyOK = false
        func finished(_ via: String, _ ok: Bool, _ why: String?) {
            pending -= 1
            if ok { anyOK = true; ways.append(via) } else if let why { lastError = "\(via): \(why)" }
            guard pending == 0 else { return }
            if anyOK {
                lastSend = (Date(), ways.joined(separator: "+"), expired)
                lastError = nil
                overlayInfo("📱 break → phone (\(what)) via \(lastSend!.via)")
            } else {
                retryAt = Date().addingTimeInterval(BreakPhonePolicy.retryEvery)
                retryExpired = expired
                lastSend = (Date(), "nothing", expired)
                overlayInfo("📱 break → phone (\(what)) reached it by no way (\(lastError ?? "?")) — retrying in \(Int(BreakPhonePolicy.retryEvery))s")
            }
        }
        pending += 1
        putInBox(sealed) { ok, why in finished("railway", ok, why) }
        if let gw = Self.gateway(), onHotspot() {
            pending += 1
            direct(sealed, gateway: gw) { ok, why in finished("hotspot", ok, why) }
        }
    }

    private func onHotspot() -> Bool {
        guard let wanted = config["HOTSPOT_SSID"], !wanted.isEmpty else { return false }
        return CWWiFiClient.shared().interface()?.ssid() == wanted
    }

    private func putInBox(_ sealed: String, done: @escaping (Bool, String?) -> Void) {
        guard let url = URL(string: "\(relayURL)/api/clip/phone") else { return done(false, "bad RELAY_URL") }
        var r = URLRequest(url: url)
        r.httpMethod = "PUT"
        r.timeoutInterval = 8
        r.setValue(relayToken, forHTTPHeaderField: "X-Bridge-Token")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["ciphertext": sealed])
        session.dataTask(with: r) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async {
                done(code == 200, code.map { "HTTP \($0)" } ?? error?.localizedDescription)
            }
        }.resume()
    }

    /// `/clip` is open on the phone (it carries only sealed data) and `ClipSync.receive`
    /// hands a `mac-break` envelope to the countdown.
    private func direct(_ sealed: String, gateway: String, done: @escaping (Bool, String?) -> Void) {
        guard let url = URL(string: "http://\(gateway):55126/clip?c=\(sealed)") else { return done(false, "bad gateway") }
        var r = URLRequest(url: url)
        r.timeoutInterval = 3
        session.dataTask(with: r) { data, _, error in
            let ok = data.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"ok\":true") == true
            DispatchQueue.main.async { done(ok, ok ? nil : (error?.localizedDescription ?? "refused")) }
        }.resume()
    }

    // MARK: - The phone → this Mac

    /// Long-polls this Mac's box while a break runs. The first answer only says where the
    /// box stands: what it holds predates the break.
    private func poll() {
        guard let url = URL(string: "\(relayURL)/api/clip/mac?after=\(pollAfter)&wait=\(primed ? 40 : 0)") else { return }
        polling = true
        var r = URLRequest(url: url)
        r.timeoutInterval = 55
        r.setValue(relayToken, forHTTPHeaderField: "X-Bridge-Token")
        let primed = self.primed
        session.dataTask(with: r) { [weak self] data, response, _ in
            let answer = (response as? HTTPURLResponse)?.statusCode == 200
                ? data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let answer {
                    self.pollAfter = answer["seq"] as? Int ?? self.pollAfter
                    if primed, let sealed = answer["ciphertext"] as? String { _ = self.take(sealed, via: "railway") }
                    self.primed = true
                }
                let again = { [weak self] in
                    guard let self else { return }
                    if self.breakState() != nil { self.poll() } else { self.polling = false }
                }
                if answer == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: again)
                } else {
                    again()
                }
            }
        }.resume()
    }

    /// One sealed request from the phone, by Railway or by `/break/phone`. Main thread.
    /// Answers the JSON the LAN route returns.
    func take(_ sealed: String, via: String) -> String {
        guard let key, let o = PhoneSeal.open(sealed, key: key) else {
            return "{\"ok\":false,\"error\":\"did not open\"}"
        }
        let now = Date()
        let breakId = current(now: now)?.breakId
        let verdict = BreakPhonePolicy.ask(o, currentBreakId: breakId, seen: Set(seen),
                                           nowMs: Int64(now.timeIntervalSince1970 * 1000))
        if let id = o["id"] as? String, verdict != .ignore { seen = Array((seen + [id]).suffix(64)) }
        switch verdict {
        case .ignore:
            return "{\"ok\":false,\"error\":\"not for the break\"}"
        case .refused(let why):
            lastAsk = (now, "refused: \(why)")
            overlayInfo("📱 phone's break request via \(via) refused: \(why)")
            return "{\"ok\":false,\"error\":\"\(why)\"}"
        case .extend(let seconds):
            lastAsk = (now, "extended +\(seconds)s via \(via)")
            overlayInfo("📱 phone extends the break by \(seconds / 60) min (via \(via))")
            onExtend(seconds)
            tick()   // the new end goes back at once
            return "{\"ok\":true,\"extendedS\":\(seconds)}"
        }
    }

    /// `/test/break/phone`.
    func stateJSON() -> String {
        let now = Date()
        func ago(_ d: Date?) -> Any { d.map { Int(now.timeIntervalSince($0)) } ?? NSNull() }
        var o: [String: Any] = [
            "enabled": timer != nil,
            "onHotspot": onHotspot(),
            "polling": polling,
            "lastSendVia": lastSend?.via ?? NSNull(),
            "lastSendAgoS": ago(lastSend?.at),
            "lastError": lastError ?? NSNull(),
            "lastAsk": lastAsk?.verdict ?? NSNull(),
            "lastAskAgoS": ago(lastAsk?.at),
        ]
        if let t = told {
            o["told"] = ["breakId": t.breakId, "endMs": t.endMs, "paused": t.paused, "leftMs": t.leftMs]
        } else {
            o["told"] = NSNull()
        }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The IPv4 default router — on the hotspot, the phone itself.
    private static func gateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "VictorMac.BreakPhone" as CFString, nil, nil),
              let v = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return v["Router"] as? String
    }

    /// victor-net's config: `KEY=value`, `#` comments, an `INCLUDE=` file whose keys lose to ours.
    static func loadConfig(path: String = NSString(string: "~/.victor-net/config.env").expandingTildeInPath) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        let own = parseConfig(text)
        guard let include = own["INCLUDE"],
              let more = try? String(contentsOfFile: NSString(string: include).expandingTildeInPath, encoding: .utf8)
        else { return own }
        return parseConfig(more).merging(own) { _, mine in mine }
    }

    static func parseConfig(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            var s = line.trimmingCharacters(in: .whitespaces)
            if let hash = s.range(of: " #") { s = String(s[..<hash.lowerBound]) }
            guard !s.hasPrefix("#"), let eq = s.firstIndex(of: "=") else { continue }
            let k = s[..<eq].trimmingCharacters(in: .whitespaces)
            let v = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { result[k] = v }
        }
        return result
    }
}
