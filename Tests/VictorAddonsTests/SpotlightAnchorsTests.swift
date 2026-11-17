import XCTest
@testable import VictorAddons

final class SpotlightAnchorsTests: XCTestCase {
    private let root = "/Users/x/My Drive"

    func testAnchorsRealDocuments() {
        XCTAssertTrue(SpotlightAnchors.wantsAnchor(path: root + "/Cursuri/AI/Agentic Engineering.pptx", root: root))
    }

    func testSkipsDriveStagingDotfilesLocksAndIconMarkers() {
        for p in ["/.tmp.driveupload/56355", "/.DS_Store", "/Cursuri/.hidden/a.txt",
                  "/Clients/~$atalog.docx", "/Vlad/Icon\r"] {
            XCTAssertFalse(SpotlightAnchors.wantsAnchor(path: root + p, root: root), p)
        }
        XCTAssertFalse(SpotlightAnchors.wantsAnchor(path: "/Users/x/Documents/a.txt", root: root))
    }

    func testPruneRemovesOnlyOrphanAnchors() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("anchors-\(UUID().uuidString)")
        let anchors = tmp.appendingPathComponent("a")
        try fm.createDirectory(at: anchors, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let alive = tmp.appendingPathComponent("alive.txt"), gone = tmp.appendingPathComponent("gone.txt")
        try "a".write(to: alive, atomically: false, encoding: .utf8)
        try "b".write(to: gone, atomically: false, encoding: .utf8)
        try fm.linkItem(at: alive, to: anchors.appendingPathComponent("1"))
        try fm.linkItem(at: gone, to: anchors.appendingPathComponent("2"))
        try fm.removeItem(at: gone)

        SpotlightAnchors.prune(dir: anchors)

        XCTAssertTrue(fm.fileExists(atPath: anchors.appendingPathComponent("1").path))
        XCTAssertFalse(fm.fileExists(atPath: anchors.appendingPathComponent("2").path))
    }
}
