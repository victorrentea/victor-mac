import CoreGraphics

/// Seconds since the last user input of any kind (mouse or keyboard) — the
/// break screen's idle test and the banner's presence check. It lived in the
/// post-break `ScreenBlackout` until that was removed (2026-11-27).
enum UserInputAge {
    static func seconds() -> CFTimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .leftMouseDragged, .keyDown, .scrollWheel, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 999
    }
}
