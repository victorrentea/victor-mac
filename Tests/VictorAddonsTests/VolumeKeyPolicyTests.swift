import XCTest
import CoreAudio
@testable import VictorAddons

/// 🔊 The volume keys as the HID tap sees them, and the steps they take.
final class VolumeKeyPolicyTests: XCTestCase {

    private func data1(key: Int, state: Int) -> Int { (key << 16) | (state << 8) }

    func testVolumeUpKeyDownIsRecognised() {
        let k = VolumeKeyPolicy.key(subtype: 8, data1: data1(key: 0, state: 0x0A))
        XCTAssertEqual(k?.kind, .up)
        XCTAssertEqual(k?.isDown, true)
    }

    func testMuteKeyUpIsRecognisedAsUp() {
        let k = VolumeKeyPolicy.key(subtype: 8, data1: data1(key: 7, state: 0x0B))
        XCTAssertEqual(k?.kind, .mute)
        XCTAssertEqual(k?.isDown, false)
    }

    /// Brightness (2/3) and play/pause (16) must reach macOS untouched.
    func testOtherMediaKeysAreLeftAlone() {
        XCTAssertNil(VolumeKeyPolicy.key(subtype: 8, data1: data1(key: 2, state: 0x0A)))
        XCTAssertNil(VolumeKeyPolicy.key(subtype: 8, data1: data1(key: 16, state: 0x0A)))
    }

    func testOtherSubtypesAreLeftAlone() {
        XCTAssertNil(VolumeKeyPolicy.key(subtype: 7, data1: data1(key: 0, state: 0x0A)))
    }

    func testOneStepIsASixteenth() {
        XCTAssertEqual(VolumeKeyPolicy.next(from: 0.5, up: true, fine: false), 9 / 16)
        XCTAssertEqual(VolumeKeyPolicy.next(from: 0.5, up: false, fine: false), 7 / 16)
    }

    func testOptionShiftStepIsASixtyFourth() {
        XCTAssertEqual(VolumeKeyPolicy.next(from: 0.5, up: true, fine: true), 33 / 64)
    }

    /// A level set elsewhere snaps onto the grid instead of drifting off it.
    func testOffGridLevelSnapsToTheGrid() {
        XCTAssertEqual(VolumeKeyPolicy.next(from: 0.53, up: true, fine: false), 9 / 16)
    }

    func testStaysWithinZeroAndOne() {
        XCTAssertEqual(VolumeKeyPolicy.next(from: 1, up: true, fine: false), 1)
        XCTAssertEqual(VolumeKeyPolicy.next(from: 0, up: false, fine: false), 0)
    }

    func testMutedShowsTheSlashedSpeaker() {
        XCTAssertEqual(VolumeKeyPolicy.symbol(level: 0.8, muted: true), "speaker.slash.fill")
        XCTAssertEqual(VolumeKeyPolicy.symbol(level: 0.8, muted: false), "speaker.wave.3.fill")
    }

    // MARK: - Which device a key moves (2026-11-25: Zoom share sound)

    private let zoom: (id: AudioDeviceID, name: String) = (90, "ZoomAudioDevice")
    private let jbl: (id: AudioDeviceID, name: String) = (40, "Victor's JBL Go 4")
    private let mac: (id: AudioDeviceID, name: String) = (10, "MacBook Pro Speakers")
    private let hdmi: (id: AudioDeviceID, name: String) = (20, "M861")

    func testARealDefaultIsMovedItself() {
        XCTAssertEqual(VolumeKeyPolicy.target(defaultDevice: jbl.id, defaultName: jbl.name,
                                              remembered: mac.id, present: [mac, jbl, zoom]), jbl.id)
    }

    /// The bug: sharing with sound, the keys moved ZoomAudioDevice and the call stayed loud.
    func testZoomShareSoundMovesTheSpeakerTheCallPlaysOn() {
        XCTAssertEqual(VolumeKeyPolicy.target(defaultDevice: zoom.id, defaultName: zoom.name,
                                              remembered: hdmi.id, present: [mac, hdmi, jbl, zoom]), hdmi.id)
    }

    func testTeamsLoopbackIsTreatedTheSame() {
        let teams: (id: AudioDeviceID, name: String) = (91, "Microsoft Teams Audio")
        XCTAssertEqual(VolumeKeyPolicy.target(defaultDevice: teams.id, defaultName: teams.name,
                                              remembered: mac.id, present: [mac, teams]), mac.id)
    }

    /// Remembered speaker gone (or the app started mid-share): the router's ladder decides.
    func testWithoutARememberedSpeakerTheLadderWins() {
        XCTAssertEqual(VolumeKeyPolicy.target(defaultDevice: zoom.id, defaultName: zoom.name,
                                              remembered: 77, present: [mac, hdmi, jbl, zoom]), jbl.id)
        XCTAssertEqual(VolumeKeyPolicy.target(defaultDevice: zoom.id, defaultName: zoom.name,
                                              remembered: nil, present: [hdmi, mac, zoom]), mac.id)
    }

    func testNothingRealLeftKeepsTheLoopback() {
        XCTAssertEqual(VolumeKeyPolicy.target(defaultDevice: zoom.id, defaultName: zoom.name,
                                              remembered: nil, present: [zoom]), zoom.id)
    }
}
