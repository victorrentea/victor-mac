import XCTest
@testable import VictorAddons

final class EditorLogoTests: XCTestCase {
    func testTheTwoReportingEditorsAreRecognised() {
        XCTAssertTrue(EditorLogo.isEditor("com.microsoft.VSCode"))
        XCTAssertTrue(EditorLogo.isEditor("com.microsoft.VSCodeInsiders"))
        XCTAssertTrue(EditorLogo.isEditor("com.jetbrains.intellij"))
        XCTAssertTrue(EditorLogo.isEditor("com.jetbrains.intellij.ce"))
        XCTAssertFalse(EditorLogo.isEditor("com.apple.Terminal"))
        XCTAssertFalse(EditorLogo.isEditor(nil))
    }

    func testTheLogoReplacesThePageEmoji() {
        XCTAssertEqual(EditorLogo.bannerText(file: "plugins/grill-me/.claude-plugin/plugin.json", hasLogo: true),
                       "plugin.json")
        XCTAssertEqual(EditorLogo.bannerText(file: "a/B.java", hasLogo: false), "📄 B.java")
    }
}
