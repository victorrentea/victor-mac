import XCTest
@testable import VictorAddons

/// Fixtures are frames captured from Victor's own receiver on 2026-09-26
/// (`Wireless Mic Rx`, v2 firmware, one transmitter — TX2 — on and full).
final class DjiReceiverProtocolTests: XCTestCase {

    private func bytes(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    // 86-byte status push: TX2 linked (byte 44 = 0x02), its slot +7 = 0x25 → level 1.
    lazy var oneTx = bytes("55 56 04 67 5a 02 00 00 00 5b 03 03 46 00 03 00 00 00 00 20 20 31 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02 00 00 00 1e 00 00 00 02 02 00 00 00 1a 98 25 04 01 00 78 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 9f d9")
    // 54-byte push: mask already says TX2, its slot has not arrived yet.
    lazy var maskAhead = bytes("55 36 04 3d 5a 02 00 00 00 5b 03 03 26 00 03 00 00 00 00 20 20 31 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02 00 00 00 1e 00 00 00 85 2c")
    // Audio-level push and a keep-alive: not status.
    lazy var level = bytes("55 17 04 38 5a 02 00 00 00 5b 03 03 07 00 05 02 00 00 00 01 00 1b d7")
    lazy var keepAlive = bytes("55 0e 04 66 5a 02 33 11 00 04 74 04 2d b8")

    func testDecodesTheLinkedTransmitterAndItsBattery() {
        let s = DjiReceiverProtocol.decodeStatus(oneTx)
        XCTAssertEqual(s, .init(linkedMask: 0x02,
                                transmitters: [.init(unit: 2, level: 1, charging: false)]))
    }

    func testMaskCanRunAheadOfTheSlot() {
        let s = DjiReceiverProtocol.decodeStatus(maskAhead)
        XCTAssertEqual(s?.linkedMask, 0x02)
        XCTAssertEqual(s?.transmitters, [])
    }

    func testOtherPushesAreNotStatus() {
        XCTAssertNil(DjiReceiverProtocol.decodeStatus(level))
        XCTAssertNil(DjiReceiverProtocol.decodeStatus(keepAlive))
    }

    func testFramesAreSplitOutOfAStreamWithGarbageAndATail() {
        var buf: [UInt8] = [0x00, 0x13] + keepAlive + oneTx + level + Array(oneTx.prefix(10))
        let frames = DjiReceiverProtocol.takeFrames(&buf)
        XCTAssertEqual(frames.map(\.count), [14, 86, 23])
        XCTAssertEqual(buf.count, 10, "the incomplete frame waits for the next read")
    }

    func testPercentIsALevelMapping() {
        XCTAssertEqual((1...7).map { DjiReceiverProtocol.percent(level: $0)! }, [100, 80, 60, 40, 20, 10, 5])
        XCTAssertNil(DjiReceiverProtocol.percent(level: 0))
    }

    func testMenuSuffix() {
        let one = DjiReceiverProtocol.decodeStatus(oneTx)
        XCTAssertEqual(DjiReceiverProtocol.menuSuffix(one, live: true), "100 %")
        XCTAssertNil(DjiReceiverProtocol.menuSuffix(one, live: false), "stale: say nothing")
        XCTAssertEqual(DjiReceiverProtocol.menuSuffix(.init(linkedMask: 0, transmitters: []), live: true), "— no TX")
        XCTAssertEqual(DjiReceiverProtocol.menuSuffix(.init(linkedMask: 3, transmitters: [
            .init(unit: 1, level: 2, charging: false), .init(unit: 2, level: 4, charging: false)]), live: true),
                       "80 % / 40 %")
        XCTAssertNil(DjiReceiverProtocol.menuSuffix(nil, live: true))
    }

    // MARK: - Policy

    private func status(_ mask: UInt8, _ txs: [(Int, Int, Bool)]) -> DjiReceiverProtocol.Status {
        .init(linkedMask: mask, transmitters: txs.map { .init(unit: $0.0, level: $0.1, charging: $0.2) })
    }
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testLowBatteryShownOnEveryChangeBelowThirtyPercentOnly() {
        var p = DjiReceiverPolicy()
        var shown: [Int] = []
        for (i, lvl) in [3, 4, 5, 5, 6, 6, 7].enumerated() {
            for e in p.feed(status(0x02, [(2, lvl, false)]), now: t0 + Double(i)) {
                if case .lowBattery(_, _, let pct) = e { shown.append(pct) }
            }
        }
        XCTAssertEqual(shown, [20, 10, 5])
    }

    /// The gauge has nothing below "5 %", so the last step repeats instead.
    func testLastStepRepeatsEveryMinuteButNotWhileCharging() {
        var p = DjiReceiverPolicy()
        var at: [TimeInterval] = []
        func feed(_ lvl: Int, _ t: TimeInterval, charging: Bool = false) {
            for e in p.feed(status(0x02, [(2, lvl, charging)]), now: t0 + t) {
                if case .lowBattery = e { at.append(t) }
            }
        }
        feed(6, 0)
        for t in stride(from: 10.0, through: 200, by: 10) { feed(7, t) }   // 7 from t=10
        XCTAssertEqual(at, [0, 10, 70, 130, 190])
        at = []
        for t in stride(from: 210.0, through: 400, by: 10) { feed(7, t, charging: true) }
        XCTAssertEqual(at, [])
    }

    /// Level 6 is a single warning, however long it lasts (an hour on 2026-11-23).
    func testOnlyTheLastStepRepeats() {
        var p = DjiReceiverPolicy()
        var n = 0
        for t in stride(from: 0.0, through: 3600, by: 30) {
            for e in p.feed(status(0x02, [(2, 6, false)]), now: t0 + t) {
                if case .lowBattery = e { n += 1 }
            }
        }
        XCTAssertEqual(n, 1)
    }

    func testLinkLossAlarmsAfterTheGraceOnceAndReportsTheReturn() {
        var p = DjiReceiverPolicy()
        _ = p.feed(status(0x02, [(2, 7, false)]), now: t0)
        XCTAssertEqual(p.feed(status(0x00, []), now: t0 + 1), [])
        XCTAssertEqual(p.feed(status(0x00, []), now: t0 + 5.9), [])
        XCTAssertEqual(p.feed(status(0x00, []), now: t0 + 6.1), [.linkLost(since: t0 + 1, lastLevel: 7)])
        XCTAssertEqual(p.feed(status(0x00, []), now: t0 + 30), [])
        XCTAssertEqual(p.feed(status(0x02, []), now: t0 + 31), [.linkBack])
    }

    func testAHiccupShorterThanTheGraceIsNothing() {
        var p = DjiReceiverPolicy()
        _ = p.feed(status(0x02, [(2, 1, false)]), now: t0)
        _ = p.feed(status(0x00, []), now: t0 + 1)
        XCTAssertEqual(p.feed(status(0x02, [(2, 1, false)]), now: t0 + 3), [])
    }

    func testDockedToChargeIsNotADeath() {
        var p = DjiReceiverPolicy()
        _ = p.feed(status(0x02, [(2, 3, true)]), now: t0)
        XCTAssertEqual(p.feed(status(0x00, []), now: t0 + 60), [])
    }

    func testNoTransmitterEverLinkedIsNotADeath() {
        var p = DjiReceiverPolicy()
        XCTAssertEqual(p.feed(status(0x00, []), now: t0 + 60), [])
    }
}

/// The one frame this app sends: auto power-off off (2026-11-27).
final class DjiReceiverAutoOffTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] { hex.split(separator: " ").map { UInt8($0, radix: 16)! } }

    // Captured from the receiver on 2026-09-26 (see DjiReceiverProtocolTests).
    lazy var oneTx = bytes("55 56 04 67 5a 02 00 00 00 5b 03 03 46 00 03 00 00 00 00 20 20 31 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02 00 00 00 1e 00 00 00 02 02 00 00 00 1a 98 25 04 01 00 78 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 9f d9")
    lazy var keepAlive = bytes("55 0e 04 66 5a 02 33 11 00 04 74 04 2d b8")
    lazy var level = bytes("55 17 04 38 5a 02 00 00 00 5b 03 03 07 00 05 02 00 00 00 01 00 1b d7")

    func testEveryCapturedFramePassesBothCrcs() {
        XCTAssertTrue(DjiReceiverProtocol.checksOut(oneTx))
        XCTAssertTrue(DjiReceiverProtocol.checksOut(keepAlive))
        XCTAssertTrue(DjiReceiverProtocol.checksOut(level))
    }

    func testACorruptFrameFailsTheCrc() {
        var f = oneTx
        f[30] ^= 0x01
        XCTAssertFalse(DjiReceiverProtocol.checksOut(f))
    }

    func testTheHeaderCrcMatchesProtocolMdExamples() {
        // PROTOCOL.md: 0x03 for a 19-byte frame, 0xfc for 22, 0x66 for the 14-byte ACK.
        XCTAssertEqual(DjiReceiverProtocol.crc8([0x55, 19, 0x04][...]), 0x03)
        XCTAssertEqual(DjiReceiverProtocol.crc8([0x55, 22, 0x04][...]), 0xfc)
        XCTAssertEqual(DjiReceiverProtocol.crc8([0x55, 14, 0x04][...]), 0x66)
    }

    func testAutoOffBitIsReadFromByte21() {
        XCTAssertEqual(DjiReceiverProtocol.receiverAutoOff(oneTx), true)   // 0x31
        var off = oneTx
        off[21] = 0x30
        XCTAssertEqual(DjiReceiverProtocol.receiverAutoOff(off), false)
        XCTAssertNil(DjiReceiverProtocol.receiverAutoOff(level))
    }

    func testTheCommandIsPROTOCOLmdsLayoutAndChecksOut() {
        let cmd = DjiReceiverProtocol.autoOffCommand(enabled: false, seq: 0x1234)
        XCTAssertEqual(cmd.count, 22)
        XCTAssertEqual(Array(cmd[0..<20]),
                       [0x55, 0x16, 0x04, 0xfc, 0x02, 0x5a, 0x34, 0x12, 0x40, 0x5b, 0x01, 0x02,
                        0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x01, 0x00])
        XCTAssertTrue(DjiReceiverProtocol.checksOut(cmd))
        XCTAssertEqual(DjiReceiverProtocol.autoOffCommand(enabled: true, seq: 1)[19], 0x01)
    }
}
