# Activity Monitors (PowerPoint, IntelliJ)

Python sidecars feeding the training-assistant daemon.

## powerpoint-monitor
Polls PowerPoint via osascript every 3s, writes `activity-slides-YYYY-MM-DD.md`:
- Activity lines with per-slide timings: `10:51:00 AI Coding.pptx - s12:10s, s13:20s`
- Pointer last line: `AI Coding.pptx:15` (read by training-assistant daemon every 0.5s)
- New line only on deck change, timings accumulate on same line
- Always runs (no toggle)

**Tech**: Python 3.12, osascript
**Output**: `TRANSCRIPTION_FOLDER/activity-slides-YYYY-MM-DD.md`

## intellij-monitor
Polls IntelliJ via osascript every 10s (only when frontmost), sends `git_file_opened` WS message to daemon when the open file changes (deduplicates against last sent value):
- Skips duplicate consecutive lines
- Training-assistant daemon reads this to provide git repos list to session participants
- Always runs (no toggle)

**Tech**: Python 3.12, osascript, git CLI
**Output**: WS message `{"type": "git_file_opened", "url": "...", "branch": "...", "file": "..."}`

## Who deduplicates an opened file (three layers, one identity)

The same event passes three filters, and they are deliberately not the same
filter:

| layer | key | scope | what it protects |
|---|---|---|---|
| editors (`live-coding` `OpenFileReporter.kt`, `victor-vsc/open-file-reporter.js`) | `rawRemoteUrl\|relPath` | **consecutive only** | a ⌘P walked through ten files flooding the wire |
| add-on, banner only (`OpenedFileBannerLog`) | canonical repo + relPath | 20h, on disk | the bottom-left flash repeating for a file already announced |
| daemon (`training-assistant` `files_md._record_into_folder`) | canonical repo + relPath | the whole session | `opened-files.md` growing duplicate rows |

**The WebSocket push is never gated on the banner log.** A repeat still carries
information to the daemon: it refreshes the entry's timestamp, follows a branch
switch, and retries a link that came back `rate-limited`, `unknown` or
`not-pushed` the first time. Muting the banner must not cost the list an event —
so `AppDelegate` pushes first and consults the log only for the flash.

`files_md`'s key is the authoritative definition of "the same file", and
`OpenedFileBannerLog.identity(url:file:)` mirrors its `_canonical_repo_url`:
host lowercased, `.git` and trailing slash gone, everything past `owner/repo`
dropped. The repo has to be in the key because `file` is **repo-relative** — a
path-only key mutes `pom.xml` in every repo but the first one opened that day.
Non-GitHub remotes still flash (the daemon refuses to list those, but the banner
is local awareness); `(none)`, the sentinel for "project open, no file
selected", flashes in neither.

The banner window is 20h: longer than a training day, so a file opened at 9:00
never flashes again at 16:00, short enough that tomorrow starts clean. It lives
in `UserDefaults` so a `build-app.sh` restart doesn't replay the morning; the log
prunes expired entries on every write and caps at 500 paths, newest kept.
`OpenedFileBannerLog.reset()` forgets everything.

## 📑 Slides seen (`SlidesSeenRecorder`, since 2026-10-29)

Every slide that stays on screen **≥ 7 s with PowerPoint in front** is recorded, so
`call-summary` and `training-summarizer` can attach / embed exactly the slides shown,
as PDF pages **exported by PowerPoint itself, links clickable** (`slides_seen.py` in
`victor-skills-private/skills/training-summarizer/`).

- **Rides on `PowerPointMonitor`'s 2 s probe** — the same AppleScript now also returns
  `slide ID` and `saved`; `onSample` hands every probe to the recorder. The thresholds
  live in the pure `SlidesSeenPolicy` (`SlidesSeenPolicyTests`): same deck path + same
  slide ID + frontmost, uninterrupted; the span closes when the slide changes,
  PowerPoint leaves the front, or quits. Always on — no share detection: the summary's
  time window is the filter (Victor, 2026-10-29: „mereu").
- **Why slide ID, not position:** Victor inserts slides mid-course; positions shift and a
  summary once embedded the wrong slide. The `<p:sldId id>` survives insert/reorder.
- **At 7 s:** if the presentation has unsaved edits **and his hands have paused** (the rule of
  every scripted save, see *When a scripted save may run* under 💾 auto-save; until 2026-11-23
  it saved whatever he was doing, mid-edit) → `save` (Victor asked for it, 2026-10-29); a slide
  he is editing at its 7th second is saved when he leaves it instead. Then a content-addressed copy of the
  deck (`decks.noindex/<sha256[:16]>.pptx`; unchanged size+mtime → no re-hash). **On close:** one
  JSON line in `log/<day>.jsonl` — start, end, seconds, deck, path, slide, slide_id,
  snapshot, presenting.
- **`slide_seen` to the training-assistant daemon (2026-11-22)** over the local WebSocket (8765),
  beside `slide_presenting_now`: `{"type":"slide_seen","phase":"qualified"|"closed","path","deck",
  "slide_id","slide","at"}` — `qualified` at 7 s (after the save above), `closed` when the span ends.
  Sent whatever the session state: the daemon files it into the active session's **seen deck** (one
  PDF page per slide shown, in its last form) or drops it. **On close, the deck is saved again** if it
  has unsaved edits, so the daemon prints the form the slide had when he left it, not the one at 7 s
  (`SlidesSeenCloseSave`, `SlidesSeenCloseSaveTests`): the closing probe's `saved` decides only when
  the active deck is still the span's; another deck in front → `PowerPointDeck.needsSave(path)` asks
  PowerPoint about the span's own; PowerPoint gone, a slide show or no file → nothing. It goes
  through `ScriptedSaveLog`, so the daemon's print waits until PowerPoint leaves the front.
  **That save, and the `closed` message with it, wait for his hands to pause** (`SlidesSeenCloseSave.step`,
  since 2026-11-23): it used to run on the very click that left the slide, and the ⌘S he pressed
  next was refused. Each probe decides again from the current state, so a ⌘S of his in the meantime
  leaves nothing to save; with PowerPoint behind another app it saves at once; after 60 s of hands
  that never pause the slide is reported as it is on disk, unsaved (AutoSave picks it up).
- **📷 toast (`SlideSeenToast`):** when the daemon actually changes the seen deck it answers
  `{"type":"slide_seen_captured","deck","slide","change":"added"|"updated"}` → 📷 (📷↻ for a new
  form of a slide already in) + PowerPoint's icon, 1.5 s, top-right of the Retina, no text, clicks
  pass through. Victor wanted it to notice a capture in a break or at night while a session is open;
  a slide shown again unchanged sends nothing.
- **Never a deck without a file** (`PowerPointDeck.hasFile`, the gate inside `save` itself):
  a scripted `save` on a new "Presentation3" does not ask where — it writes a file named
  after the first slide's title into PowerPoint's sandbox `Documents` and marks the deck
  saved, so closing it no longer warns. A new deck was lost that way on 2026-11-18.
- **Where:** `~/Library/Containers/com.microsoft.Powerpoint/Data/Documents/slides-seen/`,
  PowerPoint's own sandbox container — the only place PowerPoint opens and writes files
  driven by AppleScript **without "Grant File Access"** (it asks per file anywhere else,
  Full Disk Access does not lift it; measured 2026-10-29). Writing there needs this app's
  "access data from other apps" (App Data) grant once. **Retention:** day logs 30 days; deck
  copies and `work/` **5 days since last shown** (Victor, 2026-11-14 — at 30 days they were 350
  copies, 5.2 GB in two weeks, and a copy only serves that day's summary). Each showing sets
  the copy's mtime to now, because a copy inherits the deck's mtime and an untouched deck would
  otherwise go the day it was shown. Pruned at launch and at most hourly while recording.
- **Spotlight (2026-11-13):** the copies folder is `decks.noindex` (was `decks`, renamed once
  at launch by `migrateDecksDir`). Indexed, ~350 hash-named copies kept every real deck out
  of the ⌘Space results, though `mdfind` still found them; a Search Privacy entry fixed it,
  but that is a setting an OS update resets — the folder name is not. `.metadata_never_index`
  does **not** drop entries already indexed. `training-summarizer/slides_seen.py` reads the
  same folder. The recorder also runs `mdimport <deck>` when it first sees a deck and each
  time it goes unsaved → saved (`SpotlightReindexPolicy`): that day Spotlight missed every
  save under `~/My Drive` for ~11 h, cause not found, and the import brought each back in 2 s.
- **Measured export (2026-10-29):** 5 slides by ID out of 182 → 7 s; a 117-slide deck → 8 s,
  277 distinct URLs in the PDF vs 275 in the deck. LibreOffice dropped some links.
- **The export runs in the tart VM `wt-lab` since 2026-11-04**, never on this Mac: it used to
  open a PowerPoint window and raise the 🔒 locks in front of the presentation at the end of
  the day. `slides_seen.py` boots the VM headless (~30 s), exports, shuts it down; 8 deck
  versions took 53 s end to end. A slide came out pixel-identical to the host's export, 278
  URLs in the PDF of a deck with 276. The recording above stays on the host, only the export moved.
  - **One VM, on purpose** (Victor: *"nu-mi trebuie două niciodată"*): the same `wt-lab` as
    Walkie Talkie's lab, in `~/tart` (`TART_HOME=~/tart`), now also holding a copy of this Mac's
    PowerPoint and `~/Library/Fonts`, signed into Victor's Microsoft account. Exchange folder:
    `~/.victor-addons/vm-share`. The two never run together: already running means the lab has it,
    so the export leaves it alone.
  - No VM, busy, or a failed export → LibreOffice plus `⚠️` on stderr: fewer links, but nothing
    on screen. **Never fall back to the host's PowerPoint.**
  - New fonts or an expired sign-in: `tart run wt-lab --no-audio --dir="share:$HOME/.victor-addons/vm-share"`
    opens its window; copy the fonts or sign in there, then shut it down from inside.
    `vm-lab.sh reset` would lose PowerPoint and that sign-in.

## 💾 PowerPoint auto-save (`PowerPointAutoSave`, since 2026-11-04)

A deck on Google Drive stayed as it was until ⌘S: PowerPoint's own *AutoSave* only works on
OneDrive and SharePoint, and *Save AutoRecover info every N minutes* writes a separate recovery
file, whole minutes at best. So this app does a real save.

- **Rides on the same 2 s probe**, which already reads `saved` of the active presentation. The
  rules are in the pure `PowerPointAutoSavePolicy` (`PowerPointAutoSavePolicyTests`).
- **When:** unsaved for **3 min** **and** no mouse or keyboard input for 3 s, so a save never lands
  mid-word. Victor picked the minute over 20 s on 2026-11-04, then 3 min on 2026-11-20: every save
  now also makes the training-assistant daemon print the changed slides in PowerPoint, and that
  print shows a progress bar.
- **Scripted saves are noted** (`ScriptedSaveLog`, `~/.victor-addons/powerpoint-scripted-saves.json`,
  `{path: {started, mtime}}`): every save this app makes, AutoSave's and SlidesSeen's, so the daemon
  can tell them from Victor's ⌘S. After his ⌘S it prints at once; after one of these it waits until
  PowerPoint is no longer in front (`training-assistant/daemon/slides/save_origin.py`).
- **Never:** during a slide show (saved right after it), or for a deck with no file yet.
- **When a scripted save may run (`ScriptedSaveMoment`, 2026-11-23) — so that his ⌘S always wins.**
  Victor: *"sometimes I make a change, press ⌘S and PowerPoint says the file cannot be saved, then
  an auto-save happens"*. The mechanism: Google Drive uploads a saved deck through a temporary hard
  link (`~/My Drive/.tmp.driveupload/<n>`, see `DriveSpotlightKeeper`), held 7–15 s for a 16 MB deck
  and longer on a slow network, and **PowerPoint refuses to save a file that has a second link**
  ("The document could not be saved", measured 2026-11-18 with a permanent link). So every save shuts
  the next one out for those seconds, and each save of ours opened such a window right where he was
  working: SlidesSeen saved 7 s after he reached a slide and again on the click that left it,
  whatever his hands were doing (~100 scripted saves on 2026-11-20). The mirror case is in that
  day's log: `SlidesSeen: save … → refused` and `AutoSave: … → refused` 7 s apart, right after a
  save of his. The rule now, for AutoSave and both SlidesSeen saves:
  - **only when his hands have paused 3 s** (or PowerPoint is behind another app, where no ⌘S can
    reach it): he is then not about to press ⌘S on what he just typed;
  - **never while Drive still uploads the previous save** (`PowerPointDeck.uploading`: link count
    > 1) — AutoSave waits for the upload without restarting its 3 min;
  - **one at a time, and only if still unsaved when PowerPoint is asked** (the script answers
    `already saved`): a probe is up to 2 s old, and he may have pressed ⌘S since.
  **Not covered:** a ⌘S that comes more than 3 s after his last touch and within the upload of a
  save we made in that pause still meets Drive's link — as does his own second ⌘S within ~15 s of
  his first. Closing that needs the ⌘S itself held back until the link is gone (not built).
- **A refused save** is retried a full period (3 min) later, and only shows in
  the log (`/tmp/victor-mac.log`), as `AutoSave: save <deck> → refused`. `→ skipped, Drive still
  uploads the previous save` is the gate above, caught at the last moment.
- **The log claims only a save that wrote the file** (answer `saved` and a new mtime). A refused one
  left the file with the mtime of the save before it — his ⌘S, perhaps — and claiming that would make
  the daemon hold his print back and the badge call his save an auto-save.
- Only the **active** presentation is watched; a second edited deck waits until it is in front.
- **Measured on a 182-slide, 14 MB deck in `~/My Drive` (2026-11-04):** saved 63 s after the edit,
  PowerPoint answering 0.7 s late at worst during the save, undo still working after it. On a file
  locked with `chflags uchg` the save fails silently: no dialog, the deck stays unsaved, and
  AppleScript's `save` reports no error, hence the `saved` check after it. `chmod 444` does not
  block a save. A real refusal by Drive itself was not reproduced.

## 💾 Last save in PowerPoint's status bar (`PowerPointSavedBadge`, since 2026-11-05)

White `✓ Auto-saved · 19:21` / `✓ Saved by you · 19:21`, or amber `● Unsaved · auto-saved 19:21` /
`● Unsaved · saved by you 19:21`, centered on PowerPoint's status bar, with no pane open; the date
appears too when the last save is from another day. It answers "is everything saved?" first: an age
(`35 min ago`, until 2026-11-05 evening) read as a warning on a deck with nothing left to save.

- **Who saved (2026-11-23):** the file's mtime is looked up in `ScriptedSaveLog` (the same rule as
  the daemon's `is_scripted_save`): the save this app last made of that deck → *Auto-saved* (AutoSave
  or SlidesSeen); any other save → *by you*. The log keeps one day, so a save older than that and
  unknown to it is plain `✓ Saved · 3 Nov 22:43` / `● Unsaved · last save …`.

- **Why not the add-in:** Office.js can't write to the status bar or the title bar, has no save
  event, no last-save time (`PowerPoint.DocumentProperties` has `revisionNumber`, not a date), and
  `Office.ribbon.requestUpdate` changes a button's `enabled`, not its label.
- **The time is the file's mtime**, read at each 2 s probe, so a manual ⌘S and `PowerPointAutoSave`
  both count. The same probe gives `saved` (the amber) and the slide show state (hidden).
- **A click-through panel of ours**, not part of PowerPoint: shown only while PowerPoint is
  frontmost, and following its main window over Accessibility, 4 times a second.
