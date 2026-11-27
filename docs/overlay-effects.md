# Live-Session Overlays & the addons ↔ effects contract

WebSocket-driven participant reactions, the join-link banner, and the seam
between this app and **Victor Effects**.

> **The effects moved.** Every desktop effect, `EmojiAnimator`, `SoundManager`,
> the sound→effect map, the 🔥 whip and the soundboard live in the separate
> public repo [`victor-effects`](https://github.com/victorrentea/victor-effects)
> since 2026-09. What each effect draws, how long it lives, and why it looks the
> way it does is documented there (`victor-effects/docs/overlay-effects.md`).
> **Do not re-document an effect here.**

## Overlay components still in this app

- **`JoinLinkBanner`** — the participant join URL and its QR at the top of the
  screen. Its own `NSPanel`, with no dependency on anything that left. Two kinds:
  a **clipboard link** (menu row / `/link/publish`) and the **session's Interact
  link** (`sessionLink`, which only decides whose menu row carries the ✓).
  **Neither expires on its own** (the session link since 2026-09-24, the
  clipboard link since 2026-11-16, Victor's call both times): no countdown, no
  yellow bar, no fade, and opening the 💬 menu does not hide it. A link goes away
  only on the ✕, a second click on its menu row, the session's end, or `/link/hide`.
  **Both kinds close with one click on the red ✕** in the banner's bottom-right
  corner (2026-11-05): `BannerClosePanel` is its own panel, because the banner
  itself stays click-through, and it takes the first click without activating
  the app. Unlike the 🟢 row, the ✕ leaves the clipboard alone.
  **The session link raises itself when a session starts** (2026-11-16): the
  daemon's `session_started` carries `show_join_link: true` only when the trainer
  has just started the session, never on the re-announce after a daemon restart
  or an addons reconnect. No clipboard write on that path.
  **A click on the QR blows it up** to the largest square between the bottom of
  the screen and the link, a second click sends it back to its corner
  (`JoinLinkBanner.qrFrame`); every `show` starts small.
  **"enter this in your browser"** (2026-11-27, `JoinLinkHint`): under the large
  *session* link only, a hand-written line in Chalkduster (the hand of the sketch,
  shipped with macOS, so nothing bundled), white with a black outline, climbing 6°
  to the right into an arrow that points up at the link. Each letter rocks and bobs
  on its own beat and the arrow nudges up, so the room looks there. A separate
  click-through panel, centred, 42 % of the screen wide; hidden in the menu-bar pill
  and while the QR is blown up (it would sit on it).
  **A click on the link shrinks it into the menu bar** (2026-11-18): a pill
  centred on the screen, as tall as the bar, with no QR and no ✕; a click on the
  pill brings it back large, the QR at the size it had. Every `show` starts large.
  The switch is a 0.35 s zoom both ways: a snapshot of the text scales while the
  panel glides between the two frames, then the real label is laid out at the
  final size (`toggleCompact` → `zoom`).
  The pill fills the bar's height with text at 80 % of it (26 pt under a notch),
  big enough for a small projector. **After 10 min in the bar it fades** over 20 s
  to 20 % opacity; a hover brings it back to 100 % and keeps it there 5 more
  minutes. Both delays can be shortened for a test (`defaults write
  ro.victorrentea.macos-addons JoinLinkFadeAfter <s>` / `JoinLinkFadeAfterHover <s>`).
  The pill sits under the notch on the laptop's own panel, on purpose: a projector
  or a Zoom share sees the whole bar. It never reaches the status icons on the
  right: their left edge comes from the layer-25 windows in the bar's band
  (`CGWindowListCopyWindowInfo`, owned by Control Centre on Tahoe), re-read every
  2 s while compact. The pill moves left first and shrinks its font only when the
  whole bar left of them is too narrow (`JoinLinkBanner.compactLayout`). The app
  menus on the left are not avoided. The strip stopped being click-through for
  this; it hides what is under it anyway. The large strip now sits under the
  measured menu bar (33 pt with a notch), not under a fixed 25 pt.
  **The text fills the screen width** (2026-10-01): the font is scaled up *or*
  down until the URL spans the screen minus a 16 pt gutter, the banner is
  full-width and its height follows the text. Monospaced text scales linearly,
  so one measurement at 100 pt gives the size. Capped at 15 % of the screen
  height, so a short clipboard URL doesn't take over the room.
- **`LocalWebSocketServer`** — the link to the training-assistant daemon on
  `/ws/__overlay__`: session lifecycle (`session_started`, `session_ended`,
  which enable/disable the join-link menu item), the 🔔 bell tab, the pdf
  alarms, and the **client count that is the classroom participant count in the
  menu bar**. That last one is why the server stayed here even though its emoji
  traffic is forwarded.
- **🟢 Interact Link** (menu row) — toggles the participant join URL banner;
  enabled while a session is active. It shows a trailing **✓** while the banner
  is up (`isJoinLinkShown`, re-read on every menu open) — that tick is the
  reason the menu no longer hides this banner: you open the menu, see ✓, click
  it to take the link down.
- **`AddonsOverlayPanel` + `MinuteToken`** — the one piece of drawing that did
  *not* leave. See the coffee section below.

## The contract with Victor Effects

This app keeps **55123**; the effects app listens on **55124**
(`EffectsProxy.baseURL`, overridable with `VICTOR_EFFECTS_URL` or the
`Effects.baseURL` default). `EffectsProxy.forward` runs on the **server queue**,
never the main thread — a slow or absent effects app must not be able to freeze
the menu bar.

**Why the port did not move.** Seven local clients point at 55123 — the IntelliJ
plugin's baked default URL, the VS Code extension, `hands-off.sh`, the Chrome
extension, the prompt-capture hook, the test scripts — plus
`adb reverse tcp:55123` on the tablet's USB link and the relay, which calls
`TabletHttpServer.respond` in process and therefore covers the forwarded routes
for free. Moving them is a marketplace release and a dozen edits; one loopback
hop (~1 ms) on `/sound/play` is invisible next to the tablet's own Wi-Fi RTT.

### What is forwarded

Everything under `/effect/`, `/sound/`, `/sounds/`, `/alarm/`,
`/bt-compensation`, `/tiles`, plus `/state`, `/ping` (merged), and the historic
`/test/<effect>` aliases — **verbatim, query string included**, because a
percent-encoded flag or emoji must not be re-encoded on the way through.

### What stays local

`TabletHttpServer.localEffectNames` — exactly three:

| name | why it stayed |
|---|---|
| `training-end` | needs whisper's `VICTOR_VOICE` pulse to know the room went quiet, and that listener never left this process |
| `stop-all` | runs the local half first (stop the 🎵 soundtrack, disarm 🏁) **and then forwards**, in that order — the tablet's stop-all → play → pressed chain depends on it |
| `focus-playlist` | opens a Chrome tab; nothing is drawn, so nothing moved. Its `/test/` alias stays local with it |

Only the exact name is local: `/effect/training-end/stop` is not a carve-out for
its children and is forwarded like anything else.

### The `/ping` merge

The tablet parses **one** object, so the two halves are concatenated rather than
nested — which is why the effects app's `/ping` must stay a flat object.

- The effects half brings `soundsHash`, `tilesHash`, `effectsVersion`,
  `tabletVolume`, `panelMonitor`.
- This half brings a fragment (`onPingExtras`, collected through a short
  `DispatchQueue.main.sync` that only reads state): the Mac's clock and timezone,
  `macLanIps`, the phone-battery mirror, the screen-lock mirror,
  `trainingEndArmed`.
- Plus `effectsUp`.

**With the effects app down the answer is still `ok`, with an empty
`soundsHash`.** That is load-bearing: `MacLink.refreshSyncState` returns early
on an empty hash, so the tablet shows no amber "the Mac is stale" dot; its
`/sound/play` then gets a **404** (`effects-down`) and it plays locally.
Everything else answers **503**. Anything unparseable coming back from the
effects app is reported as down rather than spliced in, where it would break the
tablet's parser instead of one field.

`/ping` is allowed **1.5 s**, shorter than the general 3 s: the tablet pings
every 5 s and a late merged answer is worse than one saying `effectsUp:false`.

### Calls this app makes outward

`EffectsProxy.fire` (fire-and-forget, utility queue, nothing awaited and nothing
reported — a log line about a missed effect during a workshop is noise):

| trigger | fires |
|---|---|
| participant emoji over the WS (`LocalWebSocketServer.onEmoji`) | `/effect/emoji?e=&count=&glow=` |
| 🏁 `TrainingEndSequence` countdown | `/effect/progress-bar/<s>?rider=🏁`, `/effect/progress-bar/stop` |

The ⌘⌃ desktop-effect keys (Q U I O 0 9 8 7 6 5) were rows of this table until
2026-11-25; Victor Effects' own tap catches them now (`docs/hotkeys-launchers.md`).

### The one call inward: ☕

The coffee hold-charge gesture — the floating ☕, the 10 Hz cursor tick, the
charge, the pixel dissolve — is all in the effects app now, because that is
where the pixels are. **The payoff never left**: each explosion arrives as one
`GET /effects/event?type=coffee-popped&x=&y=` (`TabletHttpServer.effectsEvent` →
`AppDelegate.onEffectsEvent`), which either starts the 10-min "UNTIL BREAK"
timer zooming out of the blast, or flies a `−1` at a running break.

A webhook **per pop** rather than a batch per tick is what keeps the "first one
starts the timer, the rest fly their minute at it" rule working: the first event
has already flipped `breakTimer.isShowing` by the time the second arrives.

`MinuteToken` is the one drawing that stayed, and `docs/break-timer.md` explains
why: its target is re-sampled every frame, which a cross-process call cannot do.

## The lifecycle rule, restated

**Every overlay effect must self-terminate at its sound's length — a network
stop message is an optimisation, never the only teardown.** It is enforced in
the effects app now, but it matters *more* since the split: a lost
`/sound/stopped` is now also a lost proxy hop. The rule itself, with the
`trackEffect` / identity-guard mechanics, is documented in
`victor-effects/docs/overlay-effects.md`.

## Sound → effect mapping, in one line

A client reports `GET /sound/pressed/<file>` and `GET /sound/stopped/<file>` by
bare filename and **the Mac** decides which visual goes with it. That decision
(`SoundEffectMap`) is now the effects app's; this app only forwards the two
routes. Changing a pairing still needs no client redeploy — it just needs the
*other* app rebuilt.
