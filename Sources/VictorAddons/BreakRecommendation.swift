import Foundation

/// 👈 Which break length the ☕️ Break submenu points at, from how long Victor has
/// been talking since the last break ended (Victor, 2026-11-19): under an hour → 10
/// minutes, up to an hour and a half → 12, more than that → 15.
///
/// `nil` (no finger) when there is no last break to measure from, or it is older
/// than the 12 h the ⏱️ Resumed row also treats as stale (yesterday's last break).
enum BreakRecommendation {
    static let finger = "👈"

    static func minutes(sinceBreakEnded elapsed: TimeInterval?) -> Int? {
        guard let elapsed, (0...(12 * 3600)).contains(elapsed) else { return nil }
        if elapsed < 60 * 60 { return 10 }
        if elapsed <= 90 * 60 { return 12 }
        return 15
    }
}
