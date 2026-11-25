import AppKit

/// What the 🎙️ menu-bar item shows for the transcription choice: **the colour of the
/// microphone itself** (2026-11-25, Victor: *"vreau să colorezi iconița microfonului din
/// menu bar în roșu+blink sau portocaliu, în loc de pătrat și cerc"*). Before that the
/// state was a 🟥/🟠 emoji in a column beside the mic, and before that strokes over it.
/// The icon is the mic's own width again in every state, so nothing right of it shifts.
///
/// - `none`: 🟢 transcribing — the bar's own ink, white or black.
/// - `recording`: 🟠 recording or listening for voice — orange, steady.
/// - `pause`: 🟥 stopped — red that blinks slowly; `lit: false` is the dark half of the
///   beat, drawn in the bar's ink.
enum MicOverlay: Equatable {
    case none
    case recording
    case pause(lit: Bool)

    /// The microphone's own square.
    static let micSide: CGFloat = 18

    /// The whole icon: just the mic. `micWidth`: a wide symbol (the laptop) takes more.
    static func canvas(_ overlay: MicOverlay, micWidth: CGFloat = micSide) -> NSSize {
        NSSize(width: micWidth, height: micSide)
    }

    /// The colour the microphone is drawn in.
    static func ink(_ overlay: MicOverlay, dark: Bool) -> NSColor {
        switch overlay {
        case .none, .pause(lit: false): return dark ? .white : .black
        case .recording: return .systemOrange
        case .pause(lit: true): return .systemRed
        }
    }

    /// True when the state recolours the mic (a colour emoji fallback is then flattened
    /// into that colour, or it would not show the state at all).
    static func tints(_ overlay: MicOverlay) -> Bool { overlay != .none }
}
