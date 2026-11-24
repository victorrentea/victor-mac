import Foundation

/// 🖱️ Right button held + wheel → `ShareZoom`, no keyboard (Victor, 2026-11-24:
/// *"zoom ținând butonul din dreapta apăsat și dând scroll"*). Only while
/// `ZoomEngine.share` is chosen; with the macOS magnifier the right button is
/// left alone.
///
/// The catch is the context menu: most apps open it on the **press**, so a
/// press that went out would leave a menu over the zoom. So the press is
/// withheld at the session tap and decided at the release:
/// - a scroll came meanwhile → it was a zoom; press and release are both
///   swallowed and no menu opens;
/// - no scroll → press + release are replayed there and then (`replayClick`),
///   and the menu opens at button-up instead of button-down.
///
/// The cost is right-**drag**, which no app sees while this is on (its drags are
/// turned into plain moves). The left button was ruled out: its press cannot be
/// withheld without delaying every selection and drag on the Mac.
///
/// A value type so the rules are tested without a tap; lives on the tap thread.
struct RightScrollZoom {
    enum Verdict: Equatable {
        /// Not this gesture's — the event goes on untouched.
        case pass
        /// Ours — the app underneath never sees it.
        case swallow
        /// The release of a press that zoomed nothing: send the withheld press,
        /// then this release.
        case replayClick
    }

    /// A press is withheld and its release has not come yet.
    private(set) var held = false
    /// A scroll was taken since that press.
    private(set) var zoomed = false

    mutating func down(enabled: Bool) -> Verdict {
        held = enabled
        zoomed = false
        return enabled ? .swallow : .pass
    }

    /// Whether this scroll is a zoom step. `buttonDown` is the hardware's word:
    /// a release lost to a tap timeout must not leave every later scroll zooming.
    mutating func scroll(buttonDown: Bool) -> Bool {
        guard held else { return false }
        guard buttonDown else {
            held = false
            zoomed = false
            return false
        }
        zoomed = true
        return true
    }

    mutating func up() -> Verdict {
        guard held else { return .pass }
        let wasZoom = zoomed
        held = false
        zoomed = false
        return wasZoom ? .swallow : .replayClick
    }
}
