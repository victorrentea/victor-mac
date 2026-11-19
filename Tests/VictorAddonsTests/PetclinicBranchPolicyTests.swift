import XCTest
@testable import VictorAddons

/// 🌿 When the "petclinic is on main" pill shows, headless.
final class PetclinicBranchPolicyTests: XCTestCase {

    func testBranchFromHEAD() {
        XCTAssertEqual(PetclinicBranchPolicy.branch(fromHEAD: "ref: refs/heads/main\n"), "main")
        XCTAssertEqual(PetclinicBranchPolicy.branch(fromHEAD: "ref: refs/heads/blip26nov"), "blip26nov")
        XCTAssertEqual(PetclinicBranchPolicy.branch(fromHEAD: "ref: refs/heads/feature/x\n"), "feature/x")
        XCTAssertNil(PetclinicBranchPolicy.branch(fromHEAD: "3f2a9c0d1e2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d\n"))
        XCTAssertNil(PetclinicBranchPolicy.branch(fromHEAD: ""))
    }

    func testWarnsOnlyInASessionOnMainNotDismissedToday() {
        let w = { (active: Bool, branch: String?, dismissed: String?) in
            PetclinicBranchPolicy.shouldWarn(sessionActive: active, branch: branch,
                                             dismissedDay: dismissed, today: "2026-11-19")
        }
        XCTAssertTrue(w(true, "main", nil))
        XCTAssertTrue(w(true, "master", nil))
        XCTAssertTrue(w(true, "main", "2026-11-18"), "yesterday's dismissal does not carry over")
        XCTAssertFalse(w(true, "main", "2026-11-19"))
        XCTAssertFalse(w(false, "main", nil), "no training session, no pill")
        XCTAssertFalse(w(true, "blip26nov", nil))
        XCTAssertFalse(w(true, nil, nil), "detached HEAD or no repo")
    }

    func testDayKey() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        let d = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertEqual(PetclinicBranchPolicy.dayKey(d, calendar: cal).count, 10)
        XCTAssertEqual(PetclinicBranchPolicy.text(branch: "main"), "🌿 petclinic is on main — create this workshop's branch")
    }
}
