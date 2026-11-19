import AppKit

enum RetinaShareResolutionSettings {
    static let enabledKey = "RetinaShareResolution.enabled"
    /// The Retina's mode before the share, kept on disk so a crash or a redeploy
    /// mid-share still gives it back: "width,height,pixelWidth,pixelHeight".
    static let restoreKey = "RetinaShareResolution.restoreMode"

    /// On by default: Victor asked for it (2026-11-13; target changed to Default 2026-11-19).
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var restoreMode: [Int]? {
        get {
            let parts = (UserDefaults.standard.string(forKey: restoreKey) ?? "").split(separator: ",").compactMap { Int($0) }
            return parts.count == 4 ? parts : nil
        }
        set { UserDefaults.standard.set(newValue.map { $0.map(String.init).joined(separator: ",") }, forKey: restoreKey) }
    }
}

/// 🔻 While Zoom or Teams **shares**, the Retina switches to its **Default** mode —
/// 1728×1117 @2× (3456×2234 px), the "(Default)" row in System Settings › Displays —
/// and gets the mode it had before back when the share ends (Victor, 2026-11-19:
/// *"select 1728 × 1117 (Default) as the resolution when screen sharing"*).
///
/// **History.** From 2026-11-13 this dropped to the **1×** mode nearest in points
/// (1728×1118 px, 4.4× fewer pixels) to spare WindowServer, which sat at 100–118 % CPU
/// sharing the Retina in Zoom on 4 displays. On 2026-11-19 Victor, mid-share, put the
/// Retina back on Default by hand and asked for it to be the share mode instead.
///
/// The mode is the one macOS flags as default (`ioFlags` bit 0x4, only set on one
/// refresh), taken at the **current** refresh, so 🎞️ `RetinaRefreshCap` keeps its say.
/// Session-only (`CGConfigureDisplayWithDisplayMode … .forSession`). Main thread only.
///
/// Lives beside 🎞️ `RetinaRefreshCap` and doesn't fight it: each matches the mode the
/// other left — this one restores the *size* at whatever refresh is current.
final class RetinaShareResolution {
    /// Zoom or Teams share up (from `MeetingShareWatch`); `/test/retina-share-res?sharing=` pretends.
    var sharing = false {
        didSet { apply() }
    }

    /// Switch to Default or restore, from the setting and `sharing`. Idempotent.
    func apply() {
        guard let id = RetinaRefreshCap.builtInDisplay(), let current = CGDisplayCopyDisplayMode(id) else { return }
        if RetinaShareResolutionSettings.isEnabled && sharing {
            guard let target = Self.defaultMode(of: id, hz: current.refreshRate) else {
                overlayInfo("🔻 RetinaShareResolution: no Default mode on the Retina")
                return
            }
            guard current.width != target.width || current.height != target.height
                    || current.pixelWidth != target.pixelWidth else { return }   // already Default
            if RetinaShareResolutionSettings.restoreMode == nil {
                RetinaShareResolutionSettings.restoreMode = [current.width, current.height, current.pixelWidth, current.pixelHeight]
            }
            let err = Self.set(target, on: id)
            overlayInfo("🔻 RetinaShareResolution: sharing → Retina \(current.width)×\(current.height) → Default \(target.width)×\(target.height) (err \(err))")
        } else {
            restore()
        }
    }

    /// The Retina mode from before the share, if there is one to give back.
    func restore() {
        guard let saved = RetinaShareResolutionSettings.restoreMode else { return }
        RetinaShareResolutionSettings.restoreMode = nil
        guard let id = RetinaRefreshCap.builtInDisplay(), let current = CGDisplayCopyDisplayMode(id),
              current.pixelWidth != saved[2] || current.pixelHeight != saved[3],
              let back = Self.mode(of: id, saved: saved, hz: current.refreshRate) else { return }
        let err = Self.set(back, on: id)
        overlayInfo("🔻 RetinaShareResolution: share over → Retina back to \(back.pixelWidth)×\(back.pixelHeight) (err \(err))")
    }

    func snapshotJSON() -> String {
        let m = RetinaRefreshCap.builtInDisplay().flatMap(CGDisplayCopyDisplayMode)
        let o: [String: Any] = ["enabled": RetinaShareResolutionSettings.isEnabled, "sharing": sharing,
                                "retina": m.map { "\($0.width)x\($0.height) px=\($0.pixelWidth)x\($0.pixelHeight) @\(Int($0.refreshRate))" } ?? "",
                                "restoreMode": RetinaShareResolutionSettings.restoreMode ?? []]
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Display modes

    private static func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    /// The Retina's Default mode (the size macOS flags `kDisplayModeDefaultFlag`, 0x4 —
    /// set on one refresh only), at `hz` if that size has it, else the flagged one.
    static func defaultMode(of id: CGDirectDisplayID, hz: Double) -> CGDisplayMode? {
        let modes = allModes(id).filter { $0.isUsableForDesktopGUI() }
        guard let flagged = modes.first(where: { $0.ioFlags & 0x4 != 0 }) else { return nil }
        let same = modes.filter {
            $0.width == flagged.width && $0.height == flagged.height
                && $0.pixelWidth == flagged.pixelWidth && $0.pixelHeight == flagged.pixelHeight
        }
        return same.first { abs($0.refreshRate - hz) < 0.5 } ?? flagged
    }

    /// The mode with the saved size (points and pixels), at `hz` if it exists, else any refresh.
    static func mode(of id: CGDirectDisplayID, saved: [Int], hz: Double) -> CGDisplayMode? {
        let same = allModes(id).filter {
            $0.width == saved[0] && $0.height == saved[1] && $0.pixelWidth == saved[2] && $0.pixelHeight == saved[3]
        }
        return same.first { abs($0.refreshRate - hz) < 0.5 } ?? same.max { $0.refreshRate < $1.refreshRate }
    }

    private static func set(_ mode: CGDisplayMode, on id: CGDirectDisplayID) -> Int32 {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return -1 }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        return CGCompleteDisplayConfiguration(config, .forSession).rawValue
    }
}
