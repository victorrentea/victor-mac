import AppKit
import AVFoundation
import Foundation

/// Plays a downloaded video **in-process**, in a borderless window that covers
/// the **built-in Retina** screen and sits above everything else on it — and
/// manages its lifetime: a new play **replaces** the previous one, and the
/// player **runs the clip to its end** — never cut at a fixed minute — and is
/// then auto-closed (`killDelay`) so a snippet left up doesn't linger on the
/// projected screen.
///
/// **No 60 s cut any more (2026-11-28).** Until then every clip was closed 60 s
/// after it started, whatever was left of it; a 4:42 clip showed its first
/// minute only. Victor: "dacă vreau să mă uit la tot, de ce-l oprești?" — ESC
/// and the tablet stop it, the player does not. The minute survives only as the
/// floor of the window's lifetime, so a short clip still closes exactly as it did.
///
/// **Why no IINA any more (2026-09-24).** Until today the clip was handed to
/// IINA and its window was dragged onto the Retina through the Accessibility
/// API, then `AXFullScreen`ed there. In the room, with the Retina mirrored to
/// the projector and the ASUS made primary, that dance failed three times out
/// of three (`IINA never confirmed fullscreen`, 7 s each): IINA opened on the
/// **main** display — the ASUS — and the repeated fullscreen requests left
/// Spaces mid-transition, during which macOS swallows every click
/// ("I lost the ability to click, apparently" is in the transcript). The
/// external player bought seeking, fullscreen and a rewind-at-end, all of
/// which AVFoundation gives in-process, without a second app whose window
/// placement we do not own. So:
///
/// 1. **Which screen: the built-in one, always.** `VideoPlayer.pickScreen`
///    prefers `CGDisplayIsBuiltin`, then a name containing "Built-in", and only
///    then whatever macOS calls main (lid closed, no built-in at all). The
///    window is given that screen's `frame` verbatim — no AX coordinate flip,
///    no Spaces fullscreen, no waiting for a confirmation.
///
/// 2. **Above every other window but ScreenBrush.** Level 28 (`VideoWindow.windowLevel`,
///    the same as `GlassSpotlight`) with `canJoinAllSpaces` + `fullScreenAuxiliary`,
///    so it shows over a full-screen deck and the menu bar, on whichever Space the
///    Retina is showing — and *under* ScreenBrush's canvas at 29, so Victor can
///    draw over a clip. It was `.screenSaver` (1000) until 2026-11-26, which put
///    every ScreenBrush stroke under the picture.
///
/// 7. **✍️ A mid-clip prompt (2026-11-26)**, when the manifest entry has a
///    `prompt`: at its second the clip freezes and the subtitle itself becomes
///    editable — gold, at the bottom, the default answer selected (no box, no label); ⏎ rolls on and the answer is drawn, gold and
///    bold, during each of the prompt's cues — always, whatever ✓ Subtitles says,
///    because it is the punchline (Spartans: «HA-OOH!» reads BUILDERS!, or
///    TESTERS! if that is what he typed).
///
/// 3. **The end: rewind and pause.** At the last frame the player seeks back
///    to the snippet's start second and pauses — **SPACE replays** it, ESC or
///    the tablet closes it. A replay re-arms the auto-kill so it gets a full
///    window of its own. **Unless the clip asks to hold its end**
///    (`holdEndSeconds` in the manifest): then the last frame stays up for that
///    long — the auto-kill re-armed to it — because there the last frame *is*
///    the punchline (LGTM).
///
/// 4. **Subtitles, when a clip has them and ✓ Subtitles is on.** The switch is
///    the Victor Effects menu row (off by default, 2026-10-09), read from that
///    app's defaults domain at play time (`subtitlesOn`). A `<name>.srt` sidecar is parsed
///    (`SRTSubtitles`) and drawn as an outlined caption over the picture —
///    at the bottom, or at the top for a cue tagged `{\an8}`, in the colour of
///    its `<font color=…>` tag (white when untagged). No backdrop box.
///
/// 5. **The cursor is never hidden by us.** `setHiddenUntilMouseMoves` at most
///    — it restores itself on the first movement, so there is no hide/show
///    pair that an error path could leave unbalanced.
///
/// 6. **Seeking (2026-10-27).** A bar along the bottom of the picture
///    (`SeekBar`: elapsed, knob, `0:34 / 0:58`) shows on any mouse move and fades
///    2.5 s after the last one, so it does not sit on the projected clip. Click
///    or drag on it to seek; ← / → jump 5 s. Scrubbing out of the end (rewound
///    or held) is a replay from there, the same as SPACE.
final class VideoPlayer {
    static let shared = VideoPlayer()

    /// The window's shortest life, counted from the (re)start: a clip shorter
    /// than this stays up rewound for SPACE until then (0 disables auto-kill).
    var autoKillAfter: TimeInterval = 60
    /// How long a clip that ran past `autoKillAfter` stays up, rewound, after its end.
    var endLinger: TimeInterval = 10

    /// When to close the window, from now, with `left` seconds of clip still to
    /// play: the clip always finishes, then lingers — but never sooner than the
    /// `minimum` a short clip always had. Unknown length → the minimum.
    static func killDelay(left: TimeInterval?, minimum: TimeInterval, linger: TimeInterval) -> TimeInterval {
        guard let left, left.isFinite, left > 0 else { return minimum }
        return max(minimum, left + linger)
    }

    private var autoKill: DispatchWorkItem?
    private var window: VideoWindow?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    /// The ✍️ prompt's boundary observer (`VideoLibrary.Prompt.atSeconds`).
    private var promptObserver: Any?
    /// The app that had focus before the clip took it, given it back on close.
    private var previousApp: NSRunningApplication?

    /// 📱 What the tablet's video page needs to stay pinned: a play counts as
    /// **active** from the moment playback is asked for until the clip runs
    /// out, the window goes away, or the auto-kill fires.
    private var activeSince: Date?
    private var activeId: String?
    private var activeDeadline: Date?
    /// The clip reached its end and was rewound+paused: the window is still up
    /// (SPACE replays it) but nothing is playing, which for the tablet is over.
    private var atEndPaused = false
    private var startSeconds = 0
    /// This play's `holdEndSeconds`: 0 = rewind at the end, as usual.
    private var holdEndSeconds = 0

    /// Launch (or replace) the player at `startSeconds`, covering the Retina.
    /// Returns **how many milliseconds it is scheduled to run** — what is left of
    /// the clip after the start second — or nil if the file is
    /// missing. Same contract as `VideoSoundtrackPlayer.play`: the tablet holds
    /// its video page open for that long, and drains the ring on the tile.
    ///
    /// Main thread only (AVPlayer + NSWindow); every caller is an HTTP handler,
    /// which `TabletHttpServer` runs inside `DispatchQueue.main.sync`.
    @discardableResult
    func play(id: String, fileURL: URL, startSeconds: Int, holdEndSeconds: Int = 0,
              prompt: VideoLibrary.Prompt? = nil, volume: Float = 1) -> Int? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            overlayError("VideoPlayer: file not found: \(fileURL.path)")
            return nil
        }
        // Replace: close any player already up so we never stack windows.
        stop()

        let start = max(0, startSeconds)
        self.startSeconds = start
        self.holdEndSeconds = max(0, holdEndSeconds)
        let screen = Self.targetScreen()
        // ＋ The original, or its picture under the louder audio (`VideoBoostAudio`).
        let item = VideoBoostAudio.playerItem(id: id, fileURL: fileURL)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        p.volume = volume   // 🔉 the clip's own bar (`VideoGain`)

        let win = VideoWindow(screenFrame: screen.frame, player: p)
        win.onSpace = { [weak self] in self?.togglePause() }
        win.onEscape = { [weak self] in self?.stop() }
        win.onSeekBy = { [weak self] delta in self?.seek(by: delta) }
        win.onScrub = { [weak self] seconds, final in self?.seek(to: seconds, exact: final) }
        if Self.subtitlesOn, let srt = Self.sidecarSubtitle(for: fileURL) {
            win.subtitles = SRTSubtitles.parse(file: srt)
            overlayInfo("VideoPlayer: subtitles \(srt.lastPathComponent) (\(win.subtitles.count) cues)")
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in self?.reachedEnd() }
        if let prompt {
            win.prompt = prompt
            win.onPromptAnswered = { [weak self] in self?.promptAnswered() }
            // Fires each time playback crosses the second — a replay asks again.
            promptObserver = p.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: prompt.atSeconds, preferredTimescale: 600))],
                queue: .main
            ) { [weak self] in self?.askPrompt() }
        }
        // Every clip now, not only a subtitled one: the seek bar follows it too.
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak win, weak item] t in
            let now = CMTimeGetSeconds(t)
            if win?.subtitles.isEmpty == false { win?.showSubtitle(at: now) }
            win?.showPromptCaption(at: now)
            let d = item.map { CMTimeGetSeconds($0.duration) } ?? 0
            win?.showProgress(at: now, of: d.isFinite ? d : 0)
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        window = win
        player = p
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.setHiddenUntilMouseMoves(true)

        // Exact seek, then play: the manifest's start second IS the joke, and
        // a keyframe snap can land a scene away from it.
        p.seek(to: CMTime(seconds: Double(start), preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero) { [weak p] _ in
            p?.play()
        }

        overlayInfo("VideoPlayer: playing \(fileURL.lastPathComponent) from \(start)s on \(screen.localizedName) \(screen.frame)")
        let left = secondsLeft(fileURL: fileURL, startSeconds: start)
        activeSince = Date()
        activeId = id
        atEndPaused = false
        let planned = arm(left: left)
        return Int(planned * 1000)
    }

    /// What is left of the clip after the start second, nil when the file's
    /// duration can't be read.
    private func secondsLeft(fileURL: URL, startSeconds: Int) -> TimeInterval? {
        let d = AVURLAsset(url: fileURL).duration
        guard d.isNumeric else { return nil }
        let remaining = CMTimeGetSeconds(d) - Double(startSeconds)
        return remaining > 0 ? remaining : nil
    }

    /// What is left of the loaded clip after `from` seconds, nil when unknown.
    private func secondsLeft(from: Double) -> TimeInterval? {
        guard let item = player?.currentItem else { return nil }
        let d = CMTimeGetSeconds(item.duration)
        guard d.isFinite, d > from else { return nil }
        return d - from
    }

    /// (Re)start the clock for a play with `left` seconds to go: the tablet's
    /// deadline is the clip's end, the auto-kill `killDelay` after now. Returns
    /// the planned seconds (the auto-kill floor when the length is unknown).
    @discardableResult
    private func arm(left: TimeInterval?) -> TimeInterval {
        let planned = left ?? autoKillAfter
        activeDeadline = Date().addingTimeInterval(planned)
        scheduleAutoKill(after: Self.killDelay(left: left, minimum: autoKillAfter, linger: endLinger))
        return planned
    }

    /// 🔉 The tablet moved this clip's volume bar while it is up. Another id
    /// (the bar of a clip already replaced) changes nothing.
    func setVolume(_ volume: Float, forId id: String) {
        guard activeId == id, window != nil, let player else { return }
        player.volume = volume
    }

    /// 📱 Is a clip on screen right now? The tablet asks this once a second
    /// while its video page is pinned, so it un-pins on whichever end comes
    /// first: the clip finishing, ESC, or the auto-kill.
    var isActive: Bool {
        guard activeSince != nil, !atEndPaused, window != nil else { return false }
        if let deadline = activeDeadline, Date() >= deadline { return false }
        return true
    }

    /// The half of `GET /video/state` that speaks for the picture. Same shape as
    /// `VideoSoundtrackPlayer.stateJSON` so the tablet parses one thing.
    func stateJSON() -> String {
        let active = isActive
        let remaining = active ? (activeDeadline.map { max(0, Int($0.timeIntervalSinceNow * 1000)) } ?? 0) : 0
        let id = activeId.map { "\"\($0)\"" } ?? "null"
        return "{\"playing\":\(active),\"kind\":\"video\",\"id\":\(id),\"remainingMs\":\(remaining)}"
    }

    /// Stop playback now (tablet stop / ESC / test hook / replace) and cancel the
    /// pending auto-kill. **The one exit**: every way a clip ends comes through
    /// here, so the window, the player, the observers and the focus are all put
    /// back in one place.
    func stop() {
        autoKill?.cancel()
        autoKill = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let promptObserver, let player {
            player.removeTimeObserver(promptObserver)
        }
        promptObserver = nil
        player?.pause()
        player = nil
        if let window {
            window.orderOut(nil)
            window.close()
            self.window = nil
            // The deck underneath had the keyboard before the clip took it.
            previousApp?.activate()
        }
        previousApp = nil
        clearActive()
    }

    private func clearActive() {
        activeSince = nil
        activeId = nil
        activeDeadline = nil
        atEndPaused = false
    }

    // MARK: - Which screen

    /// The screen the clip goes on: the built-in Retina if there is one — it is
    /// what a venue projector mirrors — else what macOS calls main (lid closed).
    /// `NSScreen.main` / `screens[0]` follow the **primary** display, which at a
    /// venue is deliberately the ASUS (see `DisplayArrangementManager`).
    static func targetScreen() -> NSScreen {
        let screens = NSScreen.physical
        let candidates = screens.map { s in
            ScreenCandidate(
                isBuiltIn: (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                    .map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                name: s.localizedName,
                isMain: s == NSScreen.main
            )
        }
        if let i = pickScreen(candidates) { return screens[i] }
        return NSScreen.main ?? screens[0]
    }

    /// What `targetScreen` needs to know about a screen, so the choice can be
    /// unit-tested without an `NSScreen` (which cannot be constructed).
    struct ScreenCandidate: Equatable {
        var isBuiltIn: Bool
        var name: String
        var isMain: Bool
    }

    /// Pure half of `targetScreen`: index of the screen to use, or nil when the
    /// list is empty. Built-in first (`CGDisplayIsBuiltin`), then a name that
    /// says "Built-in" (the flag has been seen false for a built-in panel behind
    /// a DisplayLink dock), then main, then the first one.
    static func pickScreen(_ screens: [ScreenCandidate]) -> Int? {
        if let i = screens.firstIndex(where: { $0.isBuiltIn }) { return i }
        if let i = screens.firstIndex(where: { $0.name.localizedCaseInsensitiveContains("built-in") }) { return i }
        if let i = screens.firstIndex(where: { $0.isMain }) { return i }
        return screens.isEmpty ? nil : 0
    }

    // MARK: - Subtitles

    /// Subtitle sidecar extensions understood, in the order they win.
    private static let subtitleExtensions = ["srt"]

    /// Victor Effects' `✓ Subtitles` menu row — ONE switch for the soundboard
    /// captions over there and the `.srt` lines here. Read straight from its
    /// defaults domain on every play: a local read, so no HTTP hop and nothing
    /// that waits on the effects app being up. Missing (effects never launched,
    /// or never toggled) reads as off, which is the default it shows too.
    static let effectsDefaultsDomain = "ro.victorrentea.victor-effects" as CFString
    static var subtitlesOn: Bool {
        // Refresh first: cfprefsd may still hold this domain from an earlier
        // read, and a click in the other app has to count for the next video.
        CFPreferencesAppSynchronize(effectsDefaultsDomain)
        return (CFPreferencesCopyAppValue("subtitlesOn" as CFString, effectsDefaultsDomain) as? Bool) ?? false
    }

    /// The subtitle file sitting next to a clip under the same basename
    /// (`KLSdOY-6R_U.mp4` → `KLSdOY-6R_U.srt`), or nil when the clip has none.
    /// Sidecars, not a muxed track: the mp4s are downloaded artefacts that get
    /// re-fetched, so the subtitles must survive independently of them.
    static func sidecarSubtitle(for fileURL: URL) -> URL? {
        let base = fileURL.deletingPathExtension()
        return subtitleExtensions
            .map { base.appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - End of playback: rewind + pause, never advance

    /// The clip ran out: back to the start second and hold the frame, so SPACE
    /// replays it. Not `stop()`: the window stays up on purpose.
    ///
    /// A clip with `holdEndSeconds` keeps its **last** frame instead, for that
    /// long: the auto-kill is re-armed from now, since the one armed at the start
    /// would cut the hold short (LGTM ends at 58 s).
    private func reachedEnd() {
        guard let player else { return }
        player.pause()
        atEndPaused = true
        if holdEndSeconds > 0 {
            scheduleAutoKill(after: TimeInterval(holdEndSeconds))
            overlayInfo("VideoPlayer: clip ended — holding the last frame for \(holdEndSeconds)s (SPACE replays, ESC closes)")
            return
        }
        player.seek(to: CMTime(seconds: Double(startSeconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        overlayInfo("VideoPlayer: clip ended — rewound to \(startSeconds)s and paused (SPACE replays)")
    }

    /// SPACE. A replay after the end is a new play as far as everyone is
    /// concerned — its own auto-kill window, and the tablet's page pinned again.
    private func togglePause() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            return
        }
        if atEndPaused {
            atEndPaused = false
            activeSince = Date()
            arm(left: secondsLeft(from: Double(startSeconds)))
            if holdEndSeconds > 0 {
                // Held on the last frame, not rewound: go back to the start first.
                player.seek(to: CMTime(seconds: Double(startSeconds), preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in player?.play() }
                return
            }
        } else if let left = secondsLeft(from: CMTimeGetSeconds(player.currentTime())) {
            // Resumed mid-clip after a pause: the rest of it gets its full time.
            arm(left: left)
        }
        player.play()
    }

    // MARK: - ✍️ The mid-clip prompt

    /// Playback crossed the prompt's second: freeze the frame and ask. The
    /// tablet keeps its page pinned and the auto-kill restarts, so a slow answer
    /// is not cut off — but the clip still closes itself if nobody ever answers.
    private func askPrompt() {
        guard let player, let window, window.prompt != nil, player.rate > 0 else { return }
        player.pause()
        activeDeadline = Date().addingTimeInterval(autoKillAfter)
        scheduleAutoKill()
        // ScreenBrush or the deck may hold the keyboard: the field needs it.
        NSApp.activate(ignoringOtherApps: true)
        window.showPrompt()
        overlayInfo("VideoPlayer: ✍️ paused for the prompt at \(window.prompt?.atSeconds ?? 0)s")
    }

    /// ⏎ (or ESC, which keeps what is in the field): roll on, with the clip's
    /// remaining length as the tablet's new deadline.
    private func promptAnswered() {
        guard let player, let item = player.currentItem else { return }
        let left = CMTimeGetSeconds(item.duration) - CMTimeGetSeconds(player.currentTime())
        arm(left: left.isFinite ? max(1, left) : nil)
        overlayInfo("VideoPlayer: ✍️ answer \"\(window?.promptAnswer ?? "")\"")
        player.play()
    }

    // MARK: - Seeking (← / → and the seek bar)

    /// ← / →: five seconds back or forward from where the clip is now.
    private func seek(by delta: Double) {
        guard let player else { return }
        seek(to: CMTimeGetSeconds(player.currentTime()) + delta, exact: true)
        window?.revealSeekBar()
    }

    /// Jump to `seconds` in the file. While a drag is still moving (`exact`
    /// false) a little tolerance keeps the picture following the mouse; the
    /// release lands on the exact frame. A seek out of the held/rewound end is
    /// a replay from there — its own auto-kill window, the tablet's page pinned
    /// again — exactly as SPACE treats it.
    private func seek(to seconds: Double, exact: Bool) {
        guard let player, let item = player.currentItem else { return }
        let duration = CMTimeGetSeconds(item.duration)
        let target = max(0, duration.isFinite ? min(seconds, duration - 0.05) : seconds)
        let slack = exact ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        let resume = atEndPaused && exact
        if resume {
            atEndPaused = false
            activeSince = Date()
        }
        // Any landed seek moves the clip's end: a jump back must not be cut by
        // the deadline armed for the old position. (Not while the end is held
        // or rewound and this is only a drag — nothing plays then.)
        if exact && (resume || !atEndPaused) {
            arm(left: secondsLeft(from: target))
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: slack, toleranceAfter: slack) { [weak player] done in
            if done && resume { player?.play() }
        }
    }

    // MARK: - Lifetime

    private func scheduleAutoKill(after custom: TimeInterval? = nil) {
        autoKill?.cancel()
        autoKill = nil
        guard autoKillAfter > 0 else { return }
        let after = custom ?? autoKillAfter
        let work = DispatchWorkItem { [weak self] in
            self?.stop()
            overlayInfo("VideoPlayer: auto-closed player after \(Int(after))s")
        }
        autoKill = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }
}

// MARK: - The window

/// A borderless black window the size of one screen, showing an `AVPlayerLayer`
/// and, under it, a caption. Key so SPACE / ESC reach it.
final class VideoWindow: NSWindow, NSTextFieldDelegate {
    /// One under ScreenBrush's drawing canvas (29), like `GlassSpotlight`.
    static let windowLevel = NSWindow.Level(rawValue: GlassSpotlight.windowLevel)

    // ✍️ The mid-clip prompt (see `VideoPlayer`, point 7).
    var prompt: VideoLibrary.Prompt?
    /// What Victor typed last (nil = not asked yet), offered back on a replay.
    private var promptWord: String?
    /// The caption the cues show: the default until Victor answers.
    var promptAnswer: String { prompt?.caption(for: promptWord ?? "") ?? "" }
    var onPromptAnswered: (() -> Void)?
    private let promptField = NSTextField(string: "")
    private let answerLabel = NSTextField(labelWithString: "")
    private let answerOutline = NSTextField(labelWithString: "")

    var onSpace: (() -> Void)?
    var onEscape: (() -> Void)?
    /// ← / →, in seconds (±`arrowStep`).
    var onSeekBy: ((Double) -> Void)?
    /// The seek bar was clicked or dragged: target second, and whether the
    /// mouse is up (exact seek) or still moving.
    var onScrub: ((Double, Bool) -> Void)?
    var subtitles: [SRTSubtitles.Cue] = []

    static let arrowStep = 5.0
    /// The bar shows on a mouse move / arrow / scrub and fades out this long
    /// after the last one — a bar left up would sit on the projected picture.
    static let seekBarLinger: TimeInterval = 2.5
    private let seekBar = SeekBar()
    private var hideSeekBar: DispatchWorkItem?

    private let caption = NSTextField(labelWithString: "")
    /// The same text stroked thick and black, right under `caption`: the
    /// outline that keeps it readable with no backdrop box. A negative
    /// strokeWidth on one label draws a hairline, not an outline.
    private let captionOutline = NSTextField(labelWithString: "")
    private let playerLayer: AVPlayerLayer
    private let captionFont: NSFont

    init(screenFrame: CGRect, player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        // 1/15 of the screen: a line is ~8% of its height (the broadcast
        // subtitle size), read off a projector from the back of a room.
        // Regular, not heavy: heavy plus the outline read as shouting (2026-10-15).
        captionFont = .systemFont(ofSize: max(36, screenFrame.height / 15), weight: .regular)
        super.init(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Above a full-screen app and the menu bar, on every Space — but one under
        // ScreenBrush's drawing canvas (29), so Victor can draw over a clip
        // (2026-11-26; it was `.screenSaver`, which hid every stroke under it).
        level = Self.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        // Pinned to the screen's own frame; `setFrame` after init because a
        // borderless window's contentRect is also its frame, but be explicit.
        setFrame(screenFrame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let layer = playerLayer
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)

        caption.alignment = .center
        for label in [captionOutline, caption] {
            label.drawsBackground = false
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byWordWrapping
            label.isHidden = true
            view.addSubview(label)
        }
        answerLabel.alignment = .center
        for label in [answerOutline, answerLabel] {
            label.drawsBackground = false
            label.maximumNumberOfLines = 2
            label.isHidden = true
            view.addSubview(label)
        }
        buildPromptField(in: view)
        seekBar.alphaValue = 0
        seekBar.onScrub = { [weak self] seconds, final in
            self?.revealSeekBar()
            self?.onScrub?(seconds, final)
        }
        view.addSubview(seekBar)
        contentView = view
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onSpace?()      // space
        case 53: onEscape?()     // esc
        case 123: onSeekBy?(-Self.arrowStep)   // ←
        case 124: onSeekBy?(Self.arrowStep)    // →
        default: super.keyDown(with: event)
        }
    }

    /// Any mouse movement over the clip brings the seek bar up.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved { revealSeekBar() }
        super.sendEvent(event)
    }

    // MARK: Seek bar

    func showProgress(at seconds: Double, of duration: Double) {
        seekBar.duration = duration
        if !seekBar.isScrubbing { seekBar.current = seconds }
        layOutSeekBar()
    }

    /// Show the bar now and fade it out `seekBarLinger` after the last call;
    /// never while the mouse is still holding the knob.
    func revealSeekBar() {
        layOutSeekBar()
        seekBar.animator().alphaValue = 1
        hideSeekBar?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.seekBar.isScrubbing { self.revealSeekBar(); return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self.seekBar.animator().alphaValue = 0
            }
        }
        hideSeekBar = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seekBarLinger, execute: work)
    }

    /// Along the bottom of the picture (letterboxed on the 16:10 Retina), above
    /// where a bottom caption would end.
    private func layOutSeekBar() {
        let video = playerLayer.videoRect.isEmpty ? contentView?.bounds ?? frame : playerLayer.videoRect
        let height = max(36, video.height * 0.045)
        seekBar.frame = NSRect(x: video.minX + video.width * 0.03, y: video.minY + video.height * 0.015,
                               width: video.width * 0.94, height: height)
    }

    func showSubtitle(at seconds: Double) {
        guard let cue = SRTSubtitles.cue(at: seconds, in: subtitles) else {
            caption.isHidden = true
            captionOutline.isHidden = true
            return
        }
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        caption.attributedStringValue = NSAttributedString(string: cue.text, attributes: [
            .font: captionFont,
            .foregroundColor: Self.color(cue.color),
            .paragraphStyle: paragraph,
        ])
        captionOutline.attributedStringValue = NSAttributedString(string: cue.text, attributes: [
            .font: captionFont,
            .foregroundColor: NSColor.black,
            .strokeColor: NSColor.black,
            .strokeWidth: 12,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ])
        // Laid out against the picture itself, not the screen: on the 16:10
        // Retina a 16:9 clip is letterboxed, and "top" means the top of the video.
        let video = playerLayer.videoRect.isEmpty ? contentView?.bounds ?? frame : playerLayer.videoRect
        let width = video.width * 0.9
        let height = caption.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        let margin = video.height * 0.05
        let y = cue.top ? video.maxY - margin - height : video.minY + margin
        caption.frame = NSRect(x: video.minX + (video.width - width) / 2, y: y, width: width, height: height)
        captionOutline.frame = caption.frame
        caption.isHidden = false
        captionOutline.isHidden = false
    }

    // MARK: ✍️ Prompt

    /// The answer is edited IN the subtitle (Victor, 2026-11-26: "feel like I'm
    /// editing the actual movie subtitle at the bottom"): no box, no label — the
    /// field sits exactly where the caption is drawn, in its font and gold, over
    /// the same black outline, with a transparent background.
    private func buildPromptField(in view: NSView) {
        promptField.alignment = .center
        promptField.isBordered = false
        promptField.isBezeled = false
        promptField.drawsBackground = false
        promptField.focusRingType = .none
        promptField.textColor = Self.gold
        promptField.font = answerFont
        promptField.cell?.usesSingleLineMode = true
        promptField.delegate = self
        promptField.isHidden = true
        view.addSubview(promptField)   // above answerOutline, which stays behind it as the outline
    }

    private var answerFont: NSFont { .systemFont(ofSize: captionFont.pointSize * 1.35, weight: .heavy) }

    /// Frozen frame: the caption appears with the current answer selected, the
    /// caret in it, so typing replaces it. ⏎ or ESC rolls on.
    func showPrompt() {
        guard let prompt else { return }
        promptField.stringValue = shown(promptWord ?? prompt.defaultAnswer)
        layOutAnswer(promptField.stringValue)
        answerLabel.isHidden = true
        answerOutline.isHidden = false
        promptField.isHidden = false
        makeKeyAndOrderFront(nil)
        makeFirstResponder(promptField)
        if let editor = promptField.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.insertionPointColor = .white
            editor.selectAll(nil)
        }
    }

    /// As the caption will read it: uppercased when the prompt says so.
    private func shown(_ word: String) -> String {
        prompt?.uppercase == true ? word.uppercased() : word
    }

    /// Every keystroke: uppercase in place (caret kept) and redraw the outline
    /// under the field, so it reads as the subtitle the whole time.
    func controlTextDidChange(_ note: Notification) {
        // Through the field editor's own storage: `promptField.stringValue = …`
        // while editing ends the edit — the first letter typed rolled the clip on
        // with the old word (2026-11-26).
        guard let editor = promptField.currentEditor() as? NSTextView, let storage = editor.textStorage else { return }
        let typed = editor.string
        let up = shown(typed)
        if up != typed {
            let caret = editor.selectedRange()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: up)
            let len = (up as NSString).length
            editor.setSelectedRange(NSRange(location: min(caret.location, len), length: 0))
        }
        layOutAnswer(up)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === promptField else { return false }
        overlayInfo("VideoPlayer: ✍️ command \(NSStringFromSelector(selector))")
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)):
            submitPrompt()
            return true
        default:
            return false
        }
    }

    private func submitPrompt() {
        guard prompt != nil, !promptField.isHidden else { return }
        promptWord = promptField.stringValue
        promptField.isHidden = true
        answerOutline.isHidden = true
        makeFirstResponder(nil)
        onPromptAnswered?()
    }

    /// The answer, drawn during the prompt's cues: gold, heavy, a third bigger
    /// than a subtitle, outlined the same way. Not tied to ✓ Subtitles.
    func showPromptCaption(at seconds: Double) {
        guard promptField.isHidden else { return }   // being edited: the field is the caption
        guard let prompt, prompt.showsCaption(at: seconds), !promptAnswer.isEmpty else {
            answerLabel.isHidden = true
            answerOutline.isHidden = true
            return
        }
        layOutAnswer(promptAnswer)
        answerLabel.isHidden = false
        answerOutline.isHidden = false
    }

    /// Text and frame of the caption (label + outline + field all share them),
    /// at the bottom of the picture where a subtitle goes.
    private func layOutAnswer(_ text: String) {
        let font = answerFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        answerLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: Self.gold, .paragraphStyle: paragraph,
        ])
        answerOutline.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.black, .strokeColor: NSColor.black,
            .strokeWidth: 14, .shadow: shadow, .paragraphStyle: paragraph,
        ])
        let video = playerLayer.videoRect.isEmpty ? contentView?.bounds ?? frame : playerLayer.videoRect
        let width = video.width * 0.9
        let height = max(answerLabel.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height,
                         ceil(font.ascender - font.descender + font.leading) + 4)
        let rect = NSRect(x: video.minX + (video.width - width) / 2, y: video.minY + video.height * 0.05,
                          width: width, height: height)
        answerLabel.frame = rect
        answerOutline.frame = rect
        promptField.frame = rect
    }

    /// Spartan gold, the colour BUILDERS! was first burned in (#FFCC00).
    static let gold = NSColor(red: 1, green: 0.8, blue: 0, alpha: 1)

    /// A `<font color=…>` value: a few names, or `#RRGGBB`. White otherwise.
    static func color(_ value: String?) -> NSColor {
        guard let v = value?.lowercased() else { return .white }
        switch v {
        case "yellow": return NSColor(red: 1, green: 0.87, blue: 0, alpha: 1)
        case "red": return NSColor(red: 1, green: 0.2, blue: 0.15, alpha: 1)
        case "white": return .white
        default:
            guard v.hasPrefix("#"), v.count == 7, let rgb = Int(v.dropFirst(), radix: 16) else { return .white }
            return NSColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
    }
}

// MARK: - SRT

/// The subset of SubRip a training clip's sidecar uses: numbered cues,
/// `HH:MM:SS,mmm --> HH:MM:SS,mmm`, one or more lines of text, blank line.
/// Two styling tags are honoured, the rest stripped: `<font color="red">`
/// colours the cue, and the `{\an8}` position tag moves it to the top.
enum SRTSubtitles {
    struct Cue: Equatable {
        var start: Double
        var end: Double
        var text: String
        var color: String? = nil
        var top: Bool = false
    }

    static func parse(file: URL) -> [Cue] {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return parse(raw)
    }

    static func parse(_ raw: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            let text = body
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
                // No subtitle carries a music note (Victor, 2026-11-04). Taken out here,
                // not from the files: a changed `.srt` would owe a YouTube re-upload.
                .replacingOccurrences(of: "[♪♫♬] ?| ?[♪♫♬]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: text,
                            color: fontColor(body), top: body.contains("{\\an8}")))
        }
        return cues
    }

    /// `HH:MM:SS,mmm` (a `.` is tolerated for the millisecond separator).
    static func seconds(_ stamp: String) -> Double? {
        let s = stamp.replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + sec
    }

    static func cue(at t: Double, in cues: [Cue]) -> Cue? {
        cues.first { $0.start <= t && t < $0.end }
    }

    static func text(at t: Double, in cues: [Cue]) -> String? {
        cue(at: t, in: cues)?.text
    }

    /// The `color` of the first `<font color=…>` tag, quotes optional.
    static func fontColor(_ body: String) -> String? {
        guard let r = body.range(of: #"<font[^>]*color\s*=\s*"?'?([#A-Za-z0-9]+)"#, options: .regularExpression)
        else { return nil }
        let tag = String(body[r])
        return tag.range(of: #"[#A-Za-z0-9]+$"#, options: .regularExpression).map { String(tag[$0]) }
    }
}

// MARK: - Seek bar

/// The bar along the bottom of a clip: elapsed track, knob, `0:34 / 0:58`.
/// Click or drag anywhere on it to seek. Drawn, not an `NSSlider`: a slider
/// is sized for a settings pane, and this one is read off a projector.
final class SeekBar: NSView {
    var duration: Double = 0 { didSet { if duration != oldValue { needsDisplay = true } } }
    var current: Double = 0 { didSet { if current != oldValue { needsDisplay = true } } }
    var onScrub: ((Double, Bool) -> Void)?
    private(set) var isScrubbing = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var labelWidth: CGFloat { bounds.height * 3.6 }
    private var track: NSRect {
        let h = max(6, bounds.height * 0.18)
        let inset = bounds.height / 2
        return NSRect(x: inset, y: bounds.midY - h / 2,
                      width: max(0, bounds.width - labelWidth - inset * 2), height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let t = track
        let f = duration > 0 ? CGFloat(min(1, max(0, current / duration))) : 0
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: t, xRadius: t.height / 2, yRadius: t.height / 2).fill()
        var done = t
        done.size.width = t.width * f
        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: done, xRadius: t.height / 2, yRadius: t.height / 2).fill()
        let r = t.height * 1.6
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: t.minX + t.width * f - r, y: t.midY - r, width: 2 * r, height: 2 * r)).fill()

        let font = NSFont.monospacedDigitSystemFont(ofSize: bounds.height * 0.42, weight: .medium)
        let text = "\(Self.clock(current)) / \(Self.clock(duration))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.maxX - labelWidth + (labelWidth - size.width) / 2 - bounds.height / 4,
                              y: bounds.midY - size.height / 2), withAttributes: attrs)
    }

    /// `m:ss`, the way a player shows it.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// Where in the clip an x on the bar lands, clamped to the track.
    static func seconds(atX x: CGFloat, track: NSRect, duration: Double) -> Double {
        guard track.width > 0, duration > 0 else { return 0 }
        return Double(min(1, max(0, (x - track.minX) / track.width))) * duration
    }

    private func scrub(_ event: NSEvent, final: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        current = Self.seconds(atX: x, track: track, duration: duration)
        onScrub?(current, final)
    }

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        scrub(event, final: false)
    }

    override func mouseDragged(with event: NSEvent) { scrub(event, final: false) }

    override func mouseUp(with event: NSEvent) {
        scrub(event, final: true)
        isScrubbing = false
    }
}
