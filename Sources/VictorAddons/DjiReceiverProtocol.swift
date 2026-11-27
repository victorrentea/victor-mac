import Foundation

/// The DJI Mic Mini receiver's own status stream, decoded — pure, no USB.
///
/// The receiver (`Wireless Mic Rx`, USB `0x2ca3:0x4011`) has, beside its audio
/// interfaces, a vendor interface (#6, class `0xff`) whose bulk IN endpoint
/// `0x86` pushes status about ten times a second, unasked. The format is the
/// community reverse-engineering in
/// <https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md>
/// (also used live on macOS by <https://github.com/dvnkshl/MicShift>), and was
/// confirmed on Victor's own receiver on 2026-09-26 — the fixtures in
/// `DjiReceiverProtocolTests` are frames captured from it.
///
/// Framing: `0x55`, total length, `0x04`, header CRC-8, …, CRC-16. A status
/// frame carries `5b 03` at offset 9 and the firmware generation at offset 11
/// (`0x03` = v2, which is what Victor's receiver speaks; v1's layout carries no
/// battery). The v2 status push is 54 / 86 / 118 bytes for 0 / 1 / 2 linked
/// transmitters:
///   * byte 44 — which transmitters are linked (`0x01` TX1, `0x02` TX2);
///   * from byte 52, one 32-byte slot per linked TX: `+0` = `0x02`,
///     `+1` = the physical unit, `+7` = flags: `0x02` docked/charging and
///     `(b >> 2) & 7` the battery gauge, 1 (full) … 7 (about to shut off).
/// CRCs are not checked on reading: a frame whose shape does not match is
/// ignored, and a corrupt one that happens to match is corrected by the next,
/// 100 ms later. They are computed for the one frame this app ever *sends* —
/// turning the receiver's auto power-off off (`autoOffCommand`).
enum DjiReceiverProtocol {

    struct Transmitter: Equatable {
        let unit: Int
        /// 1 = full … 6 = DJI's own low-battery warning … 7 = about to shut off.
        let level: Int
        let charging: Bool
    }

    struct Status: Equatable {
        /// Bit 0x01 = TX1 linked, 0x02 = TX2 linked.
        let linkedMask: UInt8
        /// One entry per linked transmitter whose slot has arrived. The mask
        /// can run one push ahead of the slot, so a linked TX may briefly have
        /// no entry here — never the reverse.
        let transmitters: [Transmitter]

        var anyLinked: Bool { linkedMask & 0x03 != 0 }
    }

    /// Pops every complete frame off the front of `buffer`, dropping garbage.
    static func takeFrames(_ buffer: inout [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        while true {
            guard let start = buffer.firstIndex(of: 0x55) else { buffer.removeAll(); return out }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 3 else { return out }
            let length = Int(buffer[1])
            if buffer[2] != 0x04 || length < 14 {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= length else { return out }
            out.append(Array(buffer[0..<length]))
            buffer.removeFirst(length)
        }
    }

    /// The v2 status push, or nil for anything else (ACKs, the identity push,
    /// the audio-level push, v1 heartbeats).
    static func decodeStatus(_ f: [UInt8]) -> Status? {
        guard [54, 86, 118].contains(f.count), f[0] == 0x55, f[9] == 0x5b, f[10] == 0x03, f[11] == 0x03
        else { return nil }
        var txs: [Transmitter] = []
        for i in 0..<((f.count - 54) / 32) {
            let s = 52 + 32 * i
            guard f[s] == 0x02 else { return nil }
            txs.append(Transmitter(unit: Int(f[s + 1]),
                                   level: Int((f[s + 7] >> 2) & 0x07),
                                   charging: f[s + 7] & 0x02 != 0))
        }
        return Status(linkedMask: f[44], transmitters: txs)
    }

    /// Does this frame come from v1 firmware (a heartbeat with marker 0x00)?
    /// Only for the log: v1 has no battery, and this app does not decode it.
    static func isV1Heartbeat(_ f: [UInt8]) -> Bool {
        [56, 70, 84].contains(f.count) && f[9] == 0x5b && f[10] == 0x03 && f[11] == 0x00
    }

    // MARK: - Receiver auto-off (2026-11-27)

    /// Is the receiver's **auto power-off after 15 min** on? v2 status push,
    /// byte 21, bit `0x01` (PROTOCOL.md: "Auto off (receiver) active") — the
    /// only way to read it, there is no query. Nil for anything but a status push.
    ///
    /// Why it matters: on 2026-11-27 the TX went off for the lunch break at
    /// 12:32 and the receiver shut itself down at 12:47, exactly 15 min later —
    /// back from the break, Victor had to power the receiver on by hand too.
    static func receiverAutoOff(_ f: [UInt8]) -> Bool? {
        guard decodeStatus(f) != nil else { return nil }
        return f[21] & 0x01 != 0
    }

    /// DJI's DUML header CRC-8 (reflected poly `0x31`, seed `0x77`) over
    /// bytes 0…2. PROTOCOL.md gives the seed as `0xEE`, but that reproduces
    /// none of its own examples; `0x77` reproduces all of them and every frame
    /// in `DjiReceiverProtocolTests`.
    static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var c: UInt8 = 0x77
        for b in bytes {
            c ^= b
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0x8C : c >> 1 }
        }
        return c
    }

    /// DUML CRC-16 (reflected poly `0x8408`, seed `0x3692`), appended
    /// little-endian; checked against every captured frame in the tests.
    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var c: UInt16 = 0x3692
        for b in bytes {
            c ^= UInt16(b)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
        }
        return c
    }

    /// Both CRCs of a received frame are right — the proof, on the real
    /// receiver, that `autoOffCommand` is framed the way it expects.
    static func checksOut(_ f: [UInt8]) -> Bool {
        guard f.count >= 6 else { return false }
        let crc = crc16(f[0..<(f.count - 2)])
        return crc8(f[0..<3]) == f[3]
            && f[f.count - 2] == UInt8(crc & 0xff) && f[f.count - 1] == UInt8(crc >> 8)
    }

    /// v2 "set receiver setting" frame, command `0x0010` = auto off after
    /// 15 min, target `0x0000` = the receiver (PROTOCOL.md's 22-byte layout):
    /// `55 16 04 fc 02 5a seq·2 40 5b 01 02 00 00 00 00 10 00 01 <value> crc·2`.
    static func autoOffCommand(enabled: Bool, seq: UInt16) -> [UInt8] {
        var f: [UInt8] = [0x55, 22, 0x04, 0, 0x02, 0x5a, UInt8(seq & 0xff), UInt8(seq >> 8),
                          0x40, 0x5b, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00,
                          0x10, 0x00, 0x01, enabled ? 0x01 : 0x00]
        f[3] = crc8(f[0..<3])
        let crc = crc16(f[...])
        f += [UInt8(crc & 0xff), UInt8(crc >> 8)]
        return f
    }

    /// What the menu's `🎙️ Transcribing: 🎤 DJI` row appends, or nil for
    /// nothing: `80 %` (one per linked transmitter, `80 % / 40 %` for two),
    /// `— no TX` when the receiver says none is linked. Nil when the status
    /// stream is not live — a stale number is worse than none.
    static func menuSuffix(_ status: Status?, live: Bool) -> String? {
        guard live, let status else { return nil }
        guard status.anyLinked else { return "— no TX" }
        let pcts = status.transmitters.compactMap { percent(level: $0.level) }.map { "\($0) %" }
        return pcts.isEmpty ? nil : pcts.joined(separator: " / ")
    }

    /// The gauge as an approximate percentage. **A 7-step level, not a
    /// measurement**: the receiver never says more than this, so every value
    /// here is shown as `NN %` (no `≈` since 2026-10-07), and the raw level goes to the log beside it.
    ///
    /// Mapping (the one dji-mic-battery-tray uses for the same gauge,
    /// <https://github.com/chenleshu/dji-mic-battery-tray>): the five green
    /// steps are 100/80/60/40/20, then DJI's own low warning (6) and the
    /// shutdown step (7) are both below that fifth. What matters for the
    /// "under 20 %" rule is that it is exactly levels 6 and 7 — the two the
    /// DJI app itself treats as low.
    static func percent(level: Int) -> Int? {
        switch level {
        case 1: return 100
        case 2: return 80
        case 3: return 60
        case 4: return 40
        case 5: return 20
        case 6: return 10
        case 7: return 5
        default: return nil   // 0 has never been seen; treat as unknown
        }
    }
}

/// What the app does with successive status pushes. Pure: fed readings and a
/// clock, returns the announcements — the IOKit reader and the banners are
/// plumbing around it.
struct DjiReceiverPolicy {
    /// Below this, every change of the reading is shown **and heard**
    /// (2026-11-23, Victor, after the TX died mid-session with only two silent
    /// 5-second notices: *"I should hear a warning when it's under thirty
    /// percent … thirty, twenty, ten … then a warning every percentage since
    /// ten down to zero"*). On a 7-step gauge that is levels 5, 6 and 7 —
    /// 20 %, 10 %, 5 %; the gauge has no finer steps to warn on.
    static let lowPercent = 30
    /// At the last step (level 7, "5 %") the warning repeats this often —
    /// the stand-in for "every percent below ten", which the receiver never
    /// reports. On 2026-11-23 level 7 lasted 6 minutes (17:46 → 17:52).
    static let lastStepRepeat: TimeInterval = 60
    /// How long "no transmitter linked" must last before the red alarm.
    /// A transmitter re-links in a second or two after a radio hiccup; a dead
    /// one never does. 5 s is far past the first and costs nothing on the
    /// second — the alarm's own text carries the moment it began.
    static let linkLossGrace: TimeInterval = 5

    enum Event: Equatable {
        /// Show the battery tab, with a sound.
        case lowBattery(unit: Int, level: Int, percent: Int)
        /// Every level change, for the log (the only place the raw level goes).
        case levelChanged(unit: Int, level: Int, charging: Bool)
        /// Link lost for longer than the grace: raise the red alarm.
        /// `lastLevel` is the last gauge seen before it went, to word the alarm.
        case linkLost(since: Date, lastLevel: Int?)
        case linkBack
    }

    private var lastLevel: [Int: Int] = [:]
    private var lastCharging: [Int: Bool] = [:]
    /// When the last-step warning was last given, per unit.
    private var lastStepWarnedAt: [Int: Date] = [:]
    private var wasLinked = false
    private var lastLinkedLevel: Int?
    private var lastLinkedCharging = false
    private var unlinkedSince: Date?
    private var linkLossReported = false

    mutating func feed(_ s: DjiReceiverProtocol.Status, now: Date) -> [Event] {
        var events: [Event] = []
        for tx in s.transmitters {
            if lastLevel[tx.unit] != tx.level || lastCharging[tx.unit] != tx.charging {
                events.append(.levelChanged(unit: tx.unit, level: tx.level, charging: tx.charging))
                if !tx.charging, let pct = DjiReceiverProtocol.percent(level: tx.level),
                   pct < Self.lowPercent, lastLevel[tx.unit] != tx.level {
                    events.append(.lowBattery(unit: tx.unit, level: tx.level, percent: pct))
                    lastStepWarnedAt[tx.unit] = now
                }
                lastLevel[tx.unit] = tx.level
                lastCharging[tx.unit] = tx.charging
            } else if tx.level == 7, !tx.charging, let pct = DjiReceiverProtocol.percent(level: 7),
                      let warned = lastStepWarnedAt[tx.unit],
                      now.timeIntervalSince(warned) >= Self.lastStepRepeat {
                events.append(.lowBattery(unit: tx.unit, level: 7, percent: pct))
                lastStepWarnedAt[tx.unit] = now
            }
            lastLinkedLevel = tx.level
            lastLinkedCharging = tx.charging
        }
        if s.anyLinked {
            if linkLossReported { events.append(.linkBack) }
            wasLinked = true
            unlinkedSince = nil
            linkLossReported = false
        } else if wasLinked {
            // Put back in its case to charge is not a death: the last push
            // before the link went said "charging", so say nothing.
            if lastLinkedCharging {
                wasLinked = false
            } else {
                let since = unlinkedSince ?? now
                unlinkedSince = since
                if !linkLossReported, now.timeIntervalSince(since) >= Self.linkLossGrace {
                    linkLossReported = true
                    events.append(.linkLost(since: since, lastLevel: lastLinkedLevel))
                }
            }
        }
        return events
    }

    /// The receiver itself went away (unplugged): forget the link, so plugging
    /// it back in with no transmitter on does not read as a death.
    mutating func receiverGone() {
        self = DjiReceiverPolicy()
    }
}

/// **May the DJI be the microphone right now?** (2026-11-12, Victor: *"if only
/// DJI RX is connected but no TX, source should not switch to DJI"* — *"DJI
/// should only be used as a source if both RX and TX are active"*.)
///
/// The receiver alone is a USB audio device like any other, so CoreAudio lists
/// `Wireless Mic Rx` the moment it is plugged in and the ladder (XLR ▸ DJI ▸ …)
/// used to take it — then transcribed digital silence until a transmitter was
/// switched on. The receiver's own link byte says whether anything is talking
/// to it, so this app publishes that to `whisper_runner.py` as one word in a
/// file (`AppDelegate.writeDjiGate`), and Python skips the DJI unless it reads
/// `linked` or `blind`:
///
/// * `linked` — status is streaming and a transmitter is on.
/// * `no-tx` — status is streaming and none is.
/// * `absent` — no receiver, or found and not yet heard from. Blocking in that
///   gap is what keeps a plug-in from switching to the DJI for the few seconds
///   before its first status push and straight back off it.
/// * `blind` — the receiver is there but its status cannot be read (interface
///   held by another app, v1 firmware). Nothing knows, so the DJI is allowed as
///   it was before; `dead_input.py`'s digital-silence watch still raises 🎤.
///
/// A transmitter that was linked keeps `linked` for `linkLossGrace` after it
/// drops, the same grace as the red alarm: a radio hiccup re-links in a second
/// or two, and bouncing the transcription to another mic and back for it would
/// cost more than the second of silence. Put back in its case (last push said
/// charging), it goes at once.
struct DjiSourceGate {
    enum State: String { case linked, noTx = "no-tx", absent, blind }

    private var unlinkedSince: Date?
    private var wasLinked = false
    private var lastCharging = false

    mutating func feed(_ s: DjiReceiverProtocol.Status, now: Date) -> State {
        if s.anyLinked {
            wasLinked = true
            unlinkedSince = nil
            if let tx = s.transmitters.last { lastCharging = tx.charging }
            return .linked
        }
        guard wasLinked, !lastCharging else { wasLinked = false; return .noTx }
        let since = unlinkedSince ?? now
        unlinkedSince = since
        if now.timeIntervalSince(since) < DjiReceiverPolicy.linkLossGrace { return .linked }
        wasLinked = false
        unlinkedSince = nil
        return .noTx
    }

    mutating func reset() { self = DjiSourceGate() }
}
