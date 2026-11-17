import XCTest
@testable import VictorAddons

final class DriveSpotlightKeeperTests: XCTestCase {
    private let root = "/Users/x/My Drive"

    func testReimportsRealDocuments() {
        XCTAssertTrue(DriveSpotlightKeeper.wantsReimport(path: root + "/Cursuri/AI/Agentic Engineering.pptx", root: root))
    }

    func testSkipsDriveStagingDotfilesLocksAndIconMarkers() {
        for p in ["/.tmp.driveupload/56355", "/.DS_Store", "/Cursuri/.hidden/a.txt",
                  "/Clients/~$atalog.docx", "/Vlad/Icon\r"] {
            XCTAssertFalse(DriveSpotlightKeeper.wantsReimport(path: root + p, root: root), p)
        }
        XCTAssertFalse(DriveSpotlightKeeper.wantsReimport(path: "/Users/x/Documents/a.txt", root: root))
    }
}
