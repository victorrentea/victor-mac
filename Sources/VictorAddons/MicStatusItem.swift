import AppKit
import CoreAudio

/// 🎙️ **The microphone, on the bar all the time** (2026-11-19, Victor: *"another
/// menu bar item which represents the microphone which is currently selected"*).
///
/// Just the item: `MenuBarManager` draws its picture (`refreshMicItem`, the same
/// SF Symbol line drawing the 💬 icon used to carry) and fills its menu with the
/// mic rows of 🎙️ Transcribing. Created once and never removed or hidden — a
/// mic is always selected, and an item that comes and goes moves its neighbours.
/// The system default input has no notification of its own in AppKit, so a
/// CoreAudio listener redraws on its change (Whisper's own switches already
/// arrive through `setTranscribeSource`).
final class MicStatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let fill: (NSMenu) -> Void
    private let onDefaultInputChange: () -> Void
    private var listener: AudioObjectPropertyListenerBlock?

    init(fill: @escaping (NSMenu) -> Void, onDefaultInputChange: @escaping () -> Void) {
        self.fill = fill
        self.onDefaultInputChange = onDefaultInputChange
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Microphone"
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.onDefaultInputChange() }
        }
        var addr = Self.defaultInputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
            listener = block
        }
    }

    deinit {
        guard let listener else { return }
        var addr = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Skips identical redraws: the 2 s stop blink and every badge refresh land here.
    func setImage(_ image: NSImage?) {
        guard let image, let button = item.button else { return }
        if let old = button.image, old.tiffRepresentation == image.tiffRepresentation { return }
        button.image = image
    }

    func setToolTip(_ tip: String) {
        if item.button?.toolTip != tip { item.button?.toolTip = tip }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
    }
}
