import AppKit
import CoreAudio
import IOKit.hid

/// 🎙️ **The receiver's link button mutes the voice.** Victor (2026-11-16): *"când apăs
/// butonul de link de pe DJI să facă mute întotdeauna la voce și să apară un dreptunghi,
/// cum apare și volumul"* — a microphone, struck through or not.
///
/// **What the button is to the Mac** (measured that day with an `IOHIDManager` listener
/// on the receiver, `0x2ca3:0x4011`): one short press on the receiver's link button is a
/// Consumer **Volume Increment** (page 12, usage 233), value 1 then 0 a millisecond later,
/// on its HID interface (#0). Until now that reached macOS as a volume-up key, which
/// `VolumeHUD` swallowed and turned into one step of output volume.
///
/// **How:** the HID interface is opened **seized**, so macOS never sees the key (no
/// volume step, no volume HUD); a single press toggles `kAudioDevicePropertyMute` on the
/// receiver's **input** (`Wireless Mic Rx` has a settable one), which silences the voice
/// for everything that records it — Zoom/Teams, Krisp, Whisper, Walkie Talkie. Then the
/// HUD: the volume square's glass at the same spot — a red `mic.slash.fill` that stays up
/// while muted, then `mic.fill` for 1.5 s when the voice is back.
/// If the seize is refused it listens unseized (the volume step comes back) and says so.
///
/// **Two presses = Walkie Talkie's ⚡ quick question** (2026-11-25, Victor: Link pressed
/// twice starts the ⚡ question — what 🔼 ← at rest does on the mouse — so he can ask from
/// across the room; twice again while it records ends it and it is answered). A second
/// press within `DjiLinkButtonPolicy.doubleWindow` posts `POST /question/toggle` on
/// 8917–8919: at rest it opens the question, over it it ends it, over any other dictation
/// Walkie answers 409 and changes nothing. It replaces the evening of 2026-11-16's *two
/// presses = ChatGPT's voice on / off* (`POST /test/chat-voice`). The price stays that
/// **a single press mutes `doubleWindow` later**: it has to wait to learn it was not the
/// first of two.
///
/// The audio interfaces stay CoreAudio's and vendor interface #6 stays
/// `DjiReceiverMonitor`'s; this touches neither. Test: `GET /test/dji/link-press`.
final class DjiLinkButton {

    private var manager: IOHIDManager?
    private var lastPress = Date.distantPast
    private var panel: MicMuteHUDPanel?
    private var hideWork: DispatchWorkItem?
    private(set) var seized = false

    func start() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDVendorIDKey: DjiLinkButtonPolicy.vendorId,
            kIOHIDProductIDKey: DjiLinkButtonPolicy.productId,
        ] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(mgr, { context, _, _, value in
            let element = IOHIDValueGetElement(value)
            guard DjiLinkButtonPolicy.isPress(usagePage: IOHIDElementGetUsagePage(element),
                                              usage: IOHIDElementGetUsage(element),
                                              value: IOHIDValueGetIntegerValue(value)) else { return }
            Unmanaged<DjiLinkButton>.fromOpaque(context!).takeUnretainedValue().press()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        var result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        seized = result == kIOReturnSuccess
        if !seized {
            let refused = result
            result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            overlayError("🎙️ DJI link button: seize refused (0x\(String(UInt32(bitPattern: refused), radix: 16))) — "
                + (result == kIOReturnSuccess ? "listening unseized, a press also steps the volume" : "not listening"))
        } else {
            overlayInfo("🎙️ DJI link button: a press toggles the receiver's input mute")
        }
        manager = mgr
        // A mute left on (macOS keeps the switch across restarts and replugs) must be visible.
        if let device = MicInputMute.receiver(), MicInputMute.isMuted(device) == true {
            overlayInfo("🎙️ DJI receiver's input is muted from before — showing the square")
            show(muted: true)
        }
    }

    /// A press on the receiver: one mutes (once `doubleWindow` has passed with no
    /// second), two start or end Walkie Talkie's ⚡ question. Main thread.
    func press(now: Date = Date()) {
        switch DjiLinkButtonPolicy.onPress(now: now, last: lastPress, waitingForSecond: pendingSingle != nil) {
        case .bounce:
            return
        case .second:
            lastPress = now
            pendingSingle?.cancel()
            pendingSingle = nil
            toggleQuestion()
        case .first:
            lastPress = now
            let work = DispatchWorkItem { [weak self] in
                self?.pendingSingle = nil
                self?.pressed()
            }
            pendingSingle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + DjiLinkButtonPolicy.doubleWindow, execute: work)
        }
    }

    private var pendingSingle: DispatchWorkItem?

    /// Two presses: Walkie Talkie's ⚡ quick question, started or ended
    /// (`POST /question/toggle`). Asked on the port Walkie Talkie bound and nowhere else
    /// (`WalkieLoopback.targets`); a 409 is an answer (another dictation is recording)
    /// and is said, not retried elsewhere.
    @discardableResult
    func toggleQuestion(targets: [WalkieLoopback.Target]? = nil) -> String {
        let first = targets == nil
        let targets = targets ?? WalkieLoopback.targets()
        guard let target = targets.first,
              let url = URL(string: "http://127.0.0.1:\(target.port)/question/toggle") else {
            overlayError(first && WalkieLoopback.isStarting()
                         ? "🎙️ DJI link button ×2: Walkie Talkie is still starting — no ⚡ question"
                         : "🎙️ DJI link button ×2: Walkie Talkie did not answer — no ⚡ question")
            return "{\"asked\":false}"
        }
        if first { overlayInfo("🎙️ DJI link button ×2 → Walkie Talkie's ⚡ quick question (start / end)") }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        if let token = target.token { request.setValue(token, forHTTPHeaderField: "X-Walkie-Token") }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let result = body?["result"] as? String, why = body?["why"] as? String ?? ""
            DispatchQueue.main.async {
                switch (status, result) {
                case (200, .some(let r)): overlayInfo("🎙️ DJI link button ×2: ⚡ question \(r) — \(why)")
                case (409, "refused"): overlayInfo("🎙️ DJI link button ×2: no ⚡ question — \(why)")
                default: self?.toggleQuestion(targets: Array(targets.dropFirst()))
                }
            }
        }.resume()
        return "{\"asked\":true}"
    }

    /// One press, decided: the mute toggles and the square shows. Also the test hook.
    @discardableResult
    func pressed() -> String {
        guard let device = MicInputMute.receiver() else {
            overlayError("🎙️ DJI link button pressed, but no \(MicInputMute.receiverName) input to mute")
            return stateJSON()
        }
        let muted = !(MicInputMute.isMuted(device) ?? false)
        guard MicInputMute.setMuted(muted, device: device) else {
            overlayError("🎙️ DJI link button: could not \(muted ? "mute" : "unmute") the receiver's input")
            return stateJSON()
        }
        overlayInfo(muted ? "🎙️ DJI link button → voice MUTED" : "🎙️ DJI link button → voice live again")
        show(muted: muted)
        return stateJSON()
    }

    /// The square, where the volume one shows. **Muted: it stays** for as long as the mute
    /// lasts (Victor: *"un microfon tăiat pe durata mutării"*), so a forgotten mute cannot
    /// hide. Live again: the plain microphone for 1.5 s, then it fades like the volume one.
    func show(muted: Bool) {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.physical.first { NSMouseInRect(p, $0.frame, false) }
            ?? NSScreen.main ?? AppDelegate.findRetinaScreen()
        let hud = panel ?? MicMuteHUDPanel()
        panel = hud
        hud.update(muted: muted)
        hud.place(on: screen)
        hideWork?.cancel()
        hideWork = nil
        hud.alphaValue = 1
        hud.orderFrontRegardless()
        guard DjiLinkButtonPolicy.fadesOut(muted: muted) else { return }
        let work = DispatchWorkItem { [weak hud] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                hud?.animator().alphaValue = 0
            }, completionHandler: { hud?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func stateJSON() -> String {
        let device = MicInputMute.receiver()
        let muted = device.flatMap { MicInputMute.isMuted($0) }.map { $0 ? "true" : "false" } ?? "null"
        let visible = (panel?.isVisible ?? false) && (panel?.alphaValue ?? 0) > 0
        return "{\"listening\":\(manager != nil),\"seized\":\(seized),\"receiver\":\(device != nil),"
            + "\"muted\":\(muted),\"hud_visible\":\(visible)}"
    }
}

/// The decisions, without a device.
enum DjiLinkButtonPolicy {
    static let vendorId = 0x2CA3
    static let productId = 0x4011
    /// Consumer page, Volume Increment: what the link button sends.
    static let usagePage: UInt32 = 12
    static let usage: UInt32 = 233
    /// Two reports closer than this are one press (a bouncing switch).
    static let debounce: TimeInterval = 0.04
    /// A second press within this of the first makes a double; a single press acts
    /// once it has passed.
    static let doubleWindow: TimeInterval = 0.4

    enum Press: Equatable { case bounce, first, second }

    /// What a press is, given the last one and whether a first is still waiting.
    static func onPress(now: Date, last: Date, waitingForSecond: Bool) -> Press {
        let gap = now.timeIntervalSince(last)
        if gap < debounce { return .bounce }
        return waitingForSecond && gap <= doubleWindow ? .second : .first
    }

    /// The key going down; the release (value 0) a millisecond later is nothing.
    static func isPress(usagePage page: UInt32, usage u: UInt32, value: Int) -> Bool {
        page == usagePage && u == usage && value != 0
    }

    /// The struck-through microphone stays up while muted; the live one leaves by itself.
    static func fadesOut(muted: Bool) -> Bool { !muted }

    static func symbol(muted: Bool) -> String { muted ? "mic.slash.fill" : "mic.fill" }
}

/// The receiver's input mute switch (`kAudioDevicePropertyMute`, input scope).
enum MicInputMute {
    static let receiverName = "Wireless Mic Rx"

    static func receiver() -> AudioDeviceID? {
        HeadphoneMicGuard.inputDevices().first { $0.name.contains(receiverName) }?.id
    }

    private static let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    private static func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        for element in elements {
            var addr = address(element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr { return value != 0 }
        }
        return nil
    }

    /// Sets every mute element the input has; true when at least one took it.
    static func setMuted(_ muted: Bool, device: AudioDeviceID) -> Bool {
        var done = false
        for element in elements {
            var addr = address(element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &addr),
                  AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                done = true
            }
        }
        return done
    }
}

/// The volume square's glass, with a microphone in it: white when live, red and struck
/// through when muted.
final class MicMuteHUDPanel: NSPanel {

    private static let side: CGFloat = 200
    private let icon = NSImageView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]

        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        glass.material = .hudWindow
        glass.appearance = NSAppearance(named: .vibrantDark)
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 18
        glass.layer?.masksToBounds = true
        contentView = glass

        icon.frame = glass.bounds
        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignCenter
        glass.addSubview(icon)
    }

    func update(muted: Bool) {
        icon.image = NSImage(systemSymbolName: DjiLinkButtonPolicy.symbol(muted: muted),
                             accessibilityDescription: muted ? "microphone muted" : "microphone live")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 96, weight: .medium))
        icon.contentTintColor = muted ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.8)
    }

    func place(on screen: NSScreen) {
        let f = screen.frame
        setFrameOrigin(NSPoint(x: f.midX - Self.side / 2, y: f.minY + 140))
    }
}

/// **Where Walkie Talkie's loopback token may go** (2026-11-25, the Fable review of its
/// token gate — `walkie-talkie/Sources/WalkieTalkie/LoopbackToken.swift`). Walkie Talkie
/// writes a new token to `~/.walkie-talkie/test-token` at every launch and the port it
/// bound to `test-port` (`starting` until its listener is up). The token is sent to that
/// port only: asking 8917, then 8918, then 8919 with it handed the live token to whatever
/// answered on a port Walkie Talkie was not on. No `test-port` = a Walkie Talkie from
/// before it: 8917 alone; neither file = one from before the gate: all three, tokenless.
/// The files are believed only as regular files of this user, closed to group/other.
enum WalkieLoopback {
    struct Target: Equatable {
        let port: Int
        let token: String?
    }

    static let ports = [8917, 8918, 8919]

    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".walkie-talkie")
    }

    /// Re-read at every call: a relaunch writes a new token and maybe a new port. The
    /// token first — Walkie Talkie writes `starting` before a new token, so the two
    /// always belong to the same launch.
    static func targets(home: URL = home) -> [Target] {
        let token = readPrivate(home.appendingPathComponent("test-token")).flatMap { $0.isEmpty ? nil : $0 }
        let portFile = home.appendingPathComponent("test-port")
        guard exists(portFile) else {
            return token.map { [Target(port: 8917, token: $0)] } ?? ports.map { Target(port: $0, token: nil) }
        }
        guard let port = readPrivate(portFile).flatMap(Int.init), ports.contains(port) else { return [] }
        return [Target(port: port, token: token)]
    }

    static func isStarting(home: URL = home) -> Bool {
        readPrivate(home.appendingPathComponent("test-port")) == "starting"
    }

    private static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// The trimmed contents of a regular file of this uid with mode `& 077 == 0`, never
    /// through a symlink — else nil.
    static func readPrivate(_ url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              st.st_mode & 0o077 == 0, st.st_size <= 4096 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(st.st_size))
        let got = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard got >= 0 else { return nil }
        return String(decoding: bytes.prefix(got), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
