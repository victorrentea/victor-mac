import XCTest
@testable import VictorAddons

final class LunchGreetingTests: XCTestCase {
    func testLunchStartsAtThirtyMinutes() {
        XCTAssertFalse(LunchGreeting.isLunch(minutes: 15))
        XCTAssertTrue(LunchGreeting.isLunch(minutes: 30))
        XCTAssertTrue(LunchGreeting.isLunch(minutes: 45))
        XCTAssertTrue(LunchGreeting.isLunch(minutes: 60))
    }

    func testPhraseInTheCountrysLanguage() {
        XCTAssertEqual(LunchGreeting.phrase(forISO: "NL"), .init(text: "Eet smakelijk!", language: "nl-NL"))
        XCTAssertEqual(LunchGreeting.phrase(forISO: "ro").text, "Poftă bună!")
        XCTAssertEqual(LunchGreeting.phrase(forISO: "FR").language, "fr-FR")
    }

    func testUnknownCountryFallsBackToEnglish() {
        XCTAssertEqual(LunchGreeting.phrase(forISO: "ZZ"), LunchGreeting.fallback)
    }

    /// Every country Victor actually trains in has its own line, not the fallback.
    func testEveryTrainingCountryHasAPhrase() {
        for c in BreakCountry.trainingCountries where !["GB", "US", "IE", "IN", "CA"].contains(c.iso) {
            XCTAssertNotEqual(LunchGreeting.phrase(forISO: c.iso), LunchGreeting.fallback, c.name)
        }
    }
}
