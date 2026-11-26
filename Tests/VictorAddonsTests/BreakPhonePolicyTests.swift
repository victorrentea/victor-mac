import CryptoKit
import XCTest
@testable import VictorAddons

final class BreakPhonePolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { start.addingTimeInterval(60) }
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    private func s(_ remaining: Int, paused: Bool = false, at: Date? = nil, started: Date? = nil) -> PhoneBreakState {
        BreakPhonePolicy.state(remaining: remaining, paused: paused, breakStartedAt: started ?? start, now: at ?? now)
    }

    func testStateCarriesTheAbsoluteEndAndTheBreaksStartAsItsId() {
        let st = s(300)
        XCTAssertEqual(st.breakId, 1_800_000_000_000)
        XCTAssertEqual(st.endMs, nowMs + 300_000)
        XCTAssertEqual(st.leftMs, 300_000)
        XCTAssertFalse(st.paused)
    }

    /// A running watch ticks: one second later, one second less, same end. Nothing to send.
    func testTickingIsNotAChange() {
        XCTAssertFalse(BreakPhonePolicy.changed(s(300), s(299, at: now.addingTimeInterval(1))))
        // The whole-second timer may land a second late: still the same end.
        XCTAssertFalse(BreakPhonePolicy.changed(s(300), s(300, at: now.addingTimeInterval(1))))
    }

    func testExtendPauseResumeStartAndEndAreChanges() {
        XCTAssertTrue(BreakPhonePolicy.changed(s(300), s(600)))                       // +5
        XCTAssertTrue(BreakPhonePolicy.changed(s(300), s(300, paused: true)))         // ⏸
        XCTAssertTrue(BreakPhonePolicy.changed(s(300, paused: true), s(300)))         // ▶
        XCTAssertTrue(BreakPhonePolicy.changed(nil, s(300)))                          // a break starts
        XCTAssertTrue(BreakPhonePolicy.changed(s(300), nil))                          // it ends
        XCTAssertTrue(BreakPhonePolicy.changed(s(300), s(300, started: start.addingTimeInterval(5))))
        XCTAssertFalse(BreakPhonePolicy.changed(nil, nil))
    }

    /// Paused, the end slides with the wall clock; only the time left matters.
    func testWhilePausedOnlyTheTimeLeftCounts() {
        let a = s(300, paused: true)
        XCTAssertFalse(BreakPhonePolicy.changed(a, s(300, paused: true, at: now.addingTimeInterval(30))))
        XCTAssertTrue(BreakPhonePolicy.changed(a, s(600, paused: true, at: now.addingTimeInterval(30))))
    }

    /// At zero the watch gongs for ~18 s with nothing left: not a stream of resends.
    func testTheGongAtZeroIsNotAChange() {
        XCTAssertFalse(BreakPhonePolicy.changed(s(0), s(0, at: now.addingTimeInterval(10))))
    }

    func testExpiredOnlyWhenItRanOut() {
        XCTAssertTrue(BreakPhonePolicy.expired(last: s(0)))
        XCTAssertFalse(BreakPhonePolicy.expired(last: s(120)))          // ✕ mid-break
        XCTAssertFalse(BreakPhonePolicy.expired(last: s(0, paused: true)))
        XCTAssertFalse(BreakPhonePolicy.expired(last: nil))
    }

    func testEnvelopeShape() {
        let e = BreakPhonePolicy.envelope(s(300, paused: true), expired: false, id: "x", nowMs: 7)
        XCTAssertEqual(e["from"] as? String, "mac-break")
        XCTAssertEqual(e["text"] as? String, "")
        XCTAssertEqual(e["ts"] as? Int64, 7)
        let b = e["break"] as? [String: Any]
        XCTAssertEqual(b?["endMs"] as? Int64, nowMs + 300_000)
        XCTAssertEqual(b?["leftMs"] as? Int64, 300_000)
        XCTAssertEqual(b?["paused"] as? Bool, true)
        XCTAssertEqual(b?["extendS"] as? Int, 300)
        let none = BreakPhonePolicy.envelope(nil, expired: true, id: "y", nowMs: 7)
        XCTAssertTrue(none["break"] is NSNull)
        XCTAssertEqual(none["expired"] as? Bool, true)
    }

    private func ask(_ extra: [String: Any] = [:], current: Int64? = 1_800_000_000_000,
                     seen: Set<String> = []) -> BreakPhonePolicy.Ask {
        var o: [String: Any] = ["id": "r1", "ts": NSNumber(value: nowMs), "from": "phone-break",
                                "text": "", "action": "extend", "breakId": NSNumber(value: Int64(1_800_000_000_000))]
        extra.forEach { o[$0.key] = $0.value }
        return BreakPhonePolicy.ask(o, currentBreakId: current, seen: seen, nowMs: nowMs)
    }

    /// The step is the phone's +5, whatever the request says.
    func testAFreshExtendOfThisBreakIsBelieved() {
        XCTAssertEqual(ask(), .extend(seconds: 300))
        XCTAssertEqual(ask(["seconds": 3600]), .extend(seconds: 300))
    }

    /// A phone that restarted (an update mid-break) asks again; no break id needed.
    func testSyncAsksForTheStateAgain() {
        XCTAssertEqual(ask(["action": "sync"], current: nil), .sync)
        XCTAssertEqual(ask(["action": "sync"]), .sync)
    }

    func testWhatIsRefusedOrIgnored() {
        XCTAssertEqual(ask(["from": "phone"]), .ignore)                                  // a clip
        XCTAssertEqual(ask(seen: ["r1"]), .ignore)                                       // its other way
        XCTAssertEqual(ask(["ts": NSNumber(value: nowMs - 600_000)]), .refused("stale"))
        XCTAssertEqual(ask(["breakId": NSNumber(value: 1)]), .refused("another break"))
        XCTAssertEqual(ask(current: nil), .refused("no break running"))
        XCTAssertEqual(ask(["action": "close"]), .refused("unknown action"))
    }

    /// The phone rang, Victor taps +5 after the gongs: a new 5-minute break, only for the
    /// break that just ended and only shortly after.
    func testPlusFiveRightAfterTheEndStartsANewBreak() {
        let id: Int64 = 1_800_000_000_000
        func after(_ ms: Int64, ended: Int64 = id) -> BreakPhonePolicy.Ask {
            BreakPhonePolicy.ask(["id": "r9", "ts": NSNumber(value: nowMs), "from": "phone-break",
                                  "action": "extend", "breakId": NSNumber(value: id)],
                                 currentBreakId: nil, seen: [], nowMs: nowMs, lastEnded: (ended, nowMs - ms))
        }
        XCTAssertEqual(after(10_000), .restart(minutes: 5))
        XCTAssertEqual(after(10_000, ended: 1), .refused("no break running"))
        XCTAssertEqual(after(300_000), .refused("no break running"))
        // Still gonging at zero, the watch is on screen: a plain extend.
        XCTAssertEqual(ask(), .extend(seconds: 300))
    }

    /// The phone's `ClipSync.open` reads exactly this: nonce + ciphertext + tag, base64url.
    func testSealRoundTripsAndAnotherKeyCannotOpenIt() throws {
        let hex = String(repeating: "ab", count: 32)
        let key = try XCTUnwrap(PhoneSeal.key(hex: hex))
        let sealed = try XCTUnwrap(PhoneSeal.seal(["from": "mac-break", "n": 1], key: key))
        XCTAssertFalse(sealed.contains("+") || sealed.contains("/") || sealed.contains("="))
        XCTAssertEqual(PhoneSeal.open(sealed, key: key)?["from"] as? String, "mac-break")
        XCTAssertNil(PhoneSeal.open(sealed, key: PhoneSeal.key(hex: String(repeating: "cd", count: 32))!))
        XCTAssertNil(PhoneSeal.key(hex: "abc"))
    }

    func testReadsVictorNetsConfig() {
        let c = BreakPhoneMirror.parseConfig("# c\nRELAY_URL=https://x.example # where\n CLIP_KEY = ab \nbad\n")
        XCTAssertEqual(c["RELAY_URL"], "https://x.example")
        XCTAssertEqual(c["CLIP_KEY"], "ab")
        XCTAssertNil(c["bad"])
    }

    func testThePhonesSealedRouteSkipsTheTabletToken() {
        typealias P = HttpAccessPolicy
        XCTAssertEqual(P.decide(path: "/break/phone?c=abc", local: false, tokenValid: false, armed: true), .serve)
        XCTAssertEqual(P.decide(path: "/ping", local: false, tokenValid: false, armed: true), .tokenRefused)
        XCTAssertTrue(P.relayMayCall("/break/phone?c=abc"))
    }
}
