import Foundation
import XCTest
@testable import VictorAddons

/// Walkie Talkie's loopback token goes to the port it bound, and nowhere else (2026-11-25).
final class WalkieLoopbackTests: XCTestCase {
    private var home: URL!
    private let token = String(repeating: "ab", count: 32)

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("walkie-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func put(_ name: String, _ text: String, mode: Int16 = 0o600) {
        let url = home.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data((text + "\n").utf8))
        chmod(url.path, mode_t(mode))
    }

    func testTheTokenGoesToTheBoundPortOnly() {
        put("test-token", token)
        put("test-port", "8918")
        XCTAssertEqual(WalkieLoopback.targets(home: home), [.init(port: 8918, token: token)])
    }

    func testStartingAsksNobody() {
        put("test-token", token)
        put("test-port", "starting")
        XCTAssertEqual(WalkieLoopback.targets(home: home), [])
        XCTAssertTrue(WalkieLoopback.isStarting(home: home))
    }

    func testOlderWalkieTalkies() {
        // A token and no port file: 8917 alone.
        put("test-token", token)
        XCTAssertEqual(WalkieLoopback.targets(home: home), [.init(port: 8917, token: token)])
        // Neither file: all three, tokenless.
        try? FileManager.default.removeItem(at: home.appendingPathComponent("test-token"))
        XCTAssertEqual(WalkieLoopback.targets(home: home).map(\.port), [8917, 8918, 8919])
        XCTAssertTrue(WalkieLoopback.targets(home: home).allSatisfy { $0.token == nil })
    }

    func testFilesThatAreNotHisAreNotBelieved() throws {
        put("test-token", token, mode: 0o644)
        put("test-port", "8917")
        XCTAssertEqual(WalkieLoopback.targets(home: home), [.init(port: 8917, token: nil)])
        put("test-port", "8917", mode: 0o666)
        XCTAssertEqual(WalkieLoopback.targets(home: home), [])
        put("test-port", "8917")
        put("test-token", token)
        let real = home.appendingPathComponent("elsewhere")
        put("elsewhere", String(repeating: "cd", count: 32))
        try FileManager.default.removeItem(at: home.appendingPathComponent("test-token"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("test-token"), withDestinationURL: real)
        XCTAssertEqual(WalkieLoopback.targets(home: home), [.init(port: 8917, token: nil)])
    }
}
