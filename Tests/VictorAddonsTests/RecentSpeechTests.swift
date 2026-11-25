import XCTest
@testable import VictorAddons

final class RecentSpeechTests: XCTestCase {
    func testTheSpeechDropsSpeakerMarksAndFoldsWhitespace() {
        XCTAssertEqual(RecentSpeech.speech("🎙️ the broker.   👥 Throws\nan exception."),
                       "the broker. Throws an exception.")
    }

    func testThePayloadCarriesTheTranscriptAndTheWords() {
        let lines = TranscriptTail.parse("[17:52] Kafka was written in Go.\n[17:52] It keeps offsets per partition.\n")
        let out = RecentSpeech.payload(lines, seconds: 30)
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["seconds"] as? Int, 30)
        XCTAssertEqual(out["lines"] as? Int, 2)
        XCTAssertTrue((out["transcript"] as? String ?? "").contains("Kafka was written in Go."))
        XCTAssertEqual(out["speech"] as? String, "Kafka was written in Go. It keeps offsets per partition.")
        XCTAssertGreaterThanOrEqual(out["words"] as? Int ?? 0, 5)
    }

    func testAnEmptyWindowHasNoWords() {
        let out = RecentSpeech.payload([], seconds: 60)
        XCTAssertEqual(out["words"] as? Int, 0)
        XCTAssertEqual(out["speech"] as? String, "")
    }

    func testSecondsAreClamped() {
        XCTAssertEqual(RecentSpeech.clamp(nil), 30)
        XCTAssertEqual(RecentSpeech.clamp(60), 60)
        XCTAssertEqual(RecentSpeech.clamp(1), 10)
        XCTAssertEqual(RecentSpeech.clamp(10_000), 300)
        XCTAssertEqual(RecentSpeech.clamp(-.infinity), 30)
    }
}
