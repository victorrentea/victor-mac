import Foundation

/// 🎙️ **What was just said in the room, for Walkie Talkie** (2026-11-25).
///
/// `GET /transcript/tail?seconds=30` on 127.0.0.1:55123 answers the last 30 s
/// (or 60 s) of today's transcript as JSON. Walkie Talkie asks for it when a ⚡
/// question opens and offers it in a small modal — *Last 30 s* / *Last 60 s* —
/// so the question's research topic can be what the room just said (Victor:
/// *"când deschid modul întrebare, să apară o modală care să-mi permită să aleg
/// 30 s sau 60 s din transcrierea continuă din spate … Poate întreba victor-mac
/// să obțină această transcriere"*). The framing and the answer are Walkie's.
///
/// It replaced **🔬 Fact-check last 30 s / last 1 min** (2026-10-15 → 2026-11-25),
/// two menu rows that pushed the same window to Walkie's `POST /ask`; the rows
/// are gone (*"scoate fact check menu entries din victor-mac"*), the pull is the
/// one way in. Loopback only: not in `HttpAccessPolicy`'s tablet list, so the
/// network never reads the room's words.
///
/// **No waiting for whisper.** The file trails speech by about one whisper
/// batch (~8 s), so the window is really ~40 s ago → ~8 s ago. Speed wins.
enum RecentSpeech {
    /// Set by `AppDelegate`: where today's `…-transcription.txt` lives.
    static var transcriptionFolder: URL?
    static let defaultSeconds: Double = 30

    /// The route's answer: 200 with the window (maybe empty), 503 without a folder.
    static func json(seconds raw: Double?) -> (status: Int, body: String) {
        guard let folder = transcriptionFolder else {
            return (503, #"{"ok":false,"error":"no transcription folder"}"#)
        }
        let seconds = clamp(raw)
        let parsed = TranscriptTail.parse(TranscriptTail.readTail(of: TranscriptTail.todayFile(in: folder)))
        let out = payload(TranscriptTail.lastSeconds(parsed, seconds: seconds), seconds: seconds)
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let body = String(data: data, encoding: .utf8) else {
            return (500, #"{"ok":false,"error":"json"}"#)
        }
        return (200, body)
    }

    /// 10 s … 5 min; anything unreadable is the default.
    static func clamp(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0 else { return defaultSeconds }
        return min(max(raw, 10), 300)
    }

    /// Pure: the lines as Walkie reads them — `transcript` with its `[HH:MM]`
    /// stamps for the model, `speech` the words alone for the modal's header,
    /// `words` so it can tell an empty window from a real one.
    static func payload(_ lines: [TranscriptTail.Line], seconds: Double) -> [String: Any] {
        let transcript = TranscriptTail.render(lines)
        return ["ok": true, "seconds": Int(seconds), "lines": lines.count,
                "words": lines.isEmpty ? 0 : TranscriptDistiller.speechWordCount(in: transcript),
                "transcript": transcript, "speech": speech(lines.map(\.text).joined(separator: " "))]
    }

    /// The words without the speaker marks (🎙️ Victor, 👥 the room), whitespace folded.
    static func speech(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .filter { $0 != "🎙️" && $0 != "👥" }
            .joined(separator: " ")
    }
}
