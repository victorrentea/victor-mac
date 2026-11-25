# 🎙️ The last 30/60 s of speech, for Walkie Talkie (ex-🔬 Fact-check)

**What it does (2026-11-25):** `GET http://127.0.0.1:55123/transcript/tail?seconds=30` answers
the last 30 s (or 60 s — any 10…300) of today's transcript as JSON:

```json
{"ok": true, "seconds": 30, "lines": 4, "words": 57,
 "transcript": "[17:52] Kafka was written in Go.\n…", "speech": "Kafka was written in Go. …"}
```

**Who asks:** Walkie Talkie, when a ⚡ question opens (🔼 ← at rest). It shows a small modal,
*Last 30 s* / *Last 60 s*, and the one Victor clicks becomes the question's research topic
(Victor: *"când deschid modul întrebare, să apară o modală care să-mi permită să aleg 30 s sau
60 s din transcrierea continuă din spate … Poate întreba victor-mac să obțină această
transcriere"*). The framing, the answer, the 🌐 search and the 🧐 review are all Walkie's
(`walkie-talkie/Sources/WalkieTalkie/RoomPick.swift`).

**Code:** `RecentSpeech` (`Sources/VictorAddons/RecentSpeech.swift`), route `.transcriptTail` in
`TabletHttpServer`. `payload`, `speech` and `clamp` are pure and tested in `RecentSpeechTests`.

- **Loopback only.** The path is not in `HttpAccessPolicy`'s tablet list
  (`HttpAccessPolicyTests.testEverythingElseStaysOnThisMac`): the room's words never leave the Mac.
- **Window:** `TranscriptTail.lastSeconds(parsed, seconds:)` — it counts lines (~8 s each), since
  the `[HH:MM]` stamps cannot express 30 s, capped at 2 minutes back so a pick after a break does
  not reach before it. An empty window is `200` with `words: 0`; no transcription folder is `503`.
- **No waiting for whisper.** The file trails speech by about one whisper batch (~8 s), so the
  window is roughly *40 s ago → 8 s ago*. Speed is the point.

## History

- **2026-10-15 → 2026-11-25: 🔬 Fact-check last 30 s / last 1 min**, two rows of the 🎙️ menu (and
  `GET /test/research-proof`) that *pushed* the same window to Walkie's `POST /ask`, framed as an
  overheard discussion. Removed on 2026-11-25 (Victor: *"scoate fact check menu entries din
  victor-mac"*) when Walkie started *pulling* the window from its own ⚡ question. `POST /ask`
  still exists on Walkie's side for other callers.
- **Until 2026-10-15: 🔬 Fact-check last 10 min**, `research-proof.sh`: an unattended `claude`
  in a self-closing Terminal, researcher subagents, an HTML report, ~5 minutes a run. Victor:
  *"this fact check I expected to return very fast answers to me"*. Git keeps it.
