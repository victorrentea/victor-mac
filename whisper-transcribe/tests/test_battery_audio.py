"""🔋 Record on battery, transcribe on AC.

What has to hold: the audio of a battery stretch comes back as text stamped with
the minute it was spoken, in the right place in the day's file, exactly once —
and capture-only mode never loads a model.
"""
import json
import queue
import time
from datetime import datetime
from pathlib import Path

import numpy as np

import battery_audio as ba

RATE = ba.SAMPLE_RATE
BLOCK = RATE // 10


def _tone(sec: float, amp: float = 0.2) -> np.ndarray:
    return np.full(int(RATE * sec), amp, dtype=np.float32)


def _silence(sec: float) -> np.ndarray:
    return np.zeros(int(RATE * sec), dtype=np.float32)


class _Log:
    def __init__(self):
        self.lines = []

    def info(self, _c, m):
        self.lines.append(m)

    error = info


def _wait(cond, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if cond():
            return True
        time.sleep(0.02)
    return False


# ── SessionRecorder ──────────────────────────────────────────────────────────
def test_a_continuous_stretch_is_one_file_named_by_its_first_sample(tmp_path):
    rec = ba.SessionRecorder(tmp_path, "Victor")
    t0 = datetime(2026, 11, 3, 10, 15, 0).timestamp()
    for i in range(30):  # 3 s of blocks, each stamped when its callback ran
        rec.write(_tone(0.1), "DJI", 0.02, at=t0 + (i + 1) * 0.1)
    rec.stop()
    pcms = list(tmp_path.glob("*.pcm"))
    assert [p.name for p in pcms] == ["2026-11-03T10-15-00.000-Victor.s16le16k.pcm"]
    assert pcms[0].stat().st_size == 30 * BLOCK * 2
    meta = json.loads(pcms[0].with_suffix(".json").read_text())
    assert meta["device"] == "DJI" and meta["threshold"] == 0.02
    assert abs(meta["start"] - t0) < 1e-3


def test_a_gap_or_a_device_change_starts_a_new_file(tmp_path):
    """Inside a file, time is offset / rate. A gap would break that arithmetic."""
    rec = ba.SessionRecorder(tmp_path, "Victor")
    t0 = datetime(2026, 11, 3, 10, 0, 0).timestamp()
    rec.write(_tone(0.1), "DJI", 0.02, at=t0 + 0.1)
    rec.write(_tone(0.1), "DJI", 0.02, at=t0 + 0.2)
    rec.write(_tone(0.1), "DJI", 0.02, at=t0 + 60.0)  # a minute of nothing
    rec.write(_tone(0.1), "Mac", 0.02, at=t0 + 60.1)  # and a mic switch
    rec.stop()
    assert len(list(tmp_path.glob("*.pcm"))) == 3


def test_write_never_raises_into_the_audio_thread(tmp_path):
    rec = ba.SessionRecorder(tmp_path, "Victor", queue_blocks=1)
    rec._running = False  # writer gone: the queue fills
    rec._thread.join(2)
    for _ in range(5):
        rec.write(_tone(0.1), "DJI", 0.02)
    assert rec.dropped >= 4


# ── segment_offline ──────────────────────────────────────────────────────────
def test_speech_between_pauses_comes_out_at_its_own_offset():
    audio = np.concatenate([_silence(2), _tone(3), _silence(2), _tone(2), _silence(1)])
    segs = ba.segment_offline(audio, threshold=0.02)
    starts = [round(s / RATE, 1) for s, _ in segs]
    assert len(segs) == 2
    # Each chunk starts where the live buffer would have: after the last flush.
    assert starts[0] <= 2.0 and 5.0 <= starts[1] <= 7.0


def test_long_speech_is_cut_by_the_clock_with_overlap():
    segs = ba.segment_offline(_tone(30), threshold=0.02)
    starts = [s / RATE for s, _ in segs]
    # Two clock cuts keeping a 2 s overlap, then the file's end flushes what
    # is left — minus the overlap whisper has already heard.
    assert starts == [0.0, 10.0, 22.0]
    assert all(len(a) <= 12 * RATE for _, a in segs)


def test_silence_alone_sends_nothing():
    assert ba.segment_offline(_silence(60), threshold=0.02) == []


# ── merge_into_transcript ────────────────────────────────────────────────────
def test_recovered_lines_land_at_their_minute_behind_a_marker():
    existing = ["[09:58] before", "--- Victor → 🎤 ---", "[11:02] after on AC"]
    new = ["[10:15] meeting one", "[10:40] meeting two"]
    assert ba.merge_into_transcript(existing, new) == [
        "[09:58] before",
        "--- Victor → 🎤 ---",
        ba.MARKER,
        "[10:15] meeting one",
        "[10:40] meeting two",
        "[11:02] after on AC",
    ]


def test_same_minute_keeps_the_live_line_first_and_an_empty_file_works():
    assert ba.merge_into_transcript(["[10:15] live"], ["[10:15] late"]) == [
        "[10:15] live", ba.MARKER, "[10:15] late"]
    assert ba.merge_into_transcript([], ["[08:00] x"]) == [ba.MARKER, "[08:00] x"]


# ── BacklogTranscriber ───────────────────────────────────────────────────────
def _record(folder: Path, label: str, start: datetime, audio: np.ndarray):
    d = folder / ba.DIR_NAME
    d.mkdir(parents=True, exist_ok=True)
    pcm = d / f"{start:%Y-%m-%dT%H-%M-%S}.000-{label}{ba.SUFFIX}"
    (np.clip(audio, -1, 1) * 32767).astype(np.int16).tofile(pcm)
    pcm.with_suffix(".json").write_text(json.dumps(
        {"start": start.timestamp(), "label": label, "device": "x", "threshold": 0.02}))
    old = time.time() - 60
    import os
    os.utime(pcm, (old, old))
    return pcm


def test_backlog_writes_each_line_at_its_minute_drops_the_echo_and_deletes_the_audio(tmp_path):
    start = datetime(2026, 11, 3, 10, 15, 0)
    # Victor speaks at 0 s and at 70 s (10:16); the room channel echoes the first.
    me = np.concatenate([_tone(3), _silence(67), _tone(3), _silence(2)])
    room = np.concatenate([_tone(3), _silence(10)])
    _record(tmp_path, "Victor", start, me)
    _record(tmp_path, "Audience", start, room)

    texts = iter(["hello everyone", "hello everyone", "second point"])
    calls = []

    def transcribe(audio, language=None, initial_prompt=None):
        calls.append(len(audio))
        return {"text": next(texts), "language": "en"}

    written = {}
    backlog = ba.BacklogTranscriber(
        tmp_path, queue.Queue(), transcribe,
        write_lines=lambda day, lines: written.setdefault(day, []).extend(lines),
        is_garbage=lambda t: False, me_label="Victor", log=_Log())
    assert backlog.drain_once() == 1
    assert written == {"2026-11-03": ["[10:15] hello everyone", "[10:16] second point"]}
    assert list((tmp_path / ba.DIR_NAME).iterdir()) == []


def test_backlog_waits_for_the_live_queue_to_empty(tmp_path):
    _record(tmp_path, "Victor", datetime(2026, 11, 3, 10, 0), np.concatenate([_tone(2), _silence(1)]))
    live = queue.Queue()
    live.put("busy")
    seen = []
    backlog = ba.BacklogTranscriber(
        tmp_path, live, lambda a, **k: seen.append(live.qsize()) or {"text": "x", "language": "en"},
        write_lines=lambda d, l: None, is_garbage=lambda t: False, me_label="Victor", log=_Log())
    import threading
    threading.Timer(0.6, live.get).start()
    backlog.drain_once()
    assert seen == [0]


def test_a_file_still_being_written_is_left_alone(tmp_path):
    pcm = _record(tmp_path, "Victor", datetime(2026, 11, 3, 10, 0), _tone(2))
    pcm.touch()  # just written to
    assert ba.pending_recordings(tmp_path) == []


def test_backlog_marks_the_call_channel_as_audience_and_noise_as_nobody(tmp_path):
    start = datetime(2026, 11, 3, 10, 15, 0)
    _record(tmp_path, "Audience", start, np.concatenate([_tone(3), _silence(67), _tone(3), _silence(2)]))
    texts = iter(["o întrebare de la client", "Somente value é integral"])

    def transcribe(audio, language=None, initial_prompt=None):
        return {"text": next(texts), "language": "ro"}

    written = {}
    ba.BacklogTranscriber(
        tmp_path, queue.Queue(), transcribe,
        write_lines=lambda day, lines: written.setdefault(day, []).extend(lines),
        is_garbage=lambda t: False, me_label="Victor", log=_Log()).drain_once()
    assert written == {"2026-11-03": [
        "[10:15] 👥 o întrebare de la client", "[10:16] Somente value é integral"]}


# ── 👂 VoiceSentinel: after Stop ❌, resume when somebody talks ──────────────
def _speech_levels(sec: float, loud: float = 0.2, quiet: float = 0.01):
    """Syllables and pauses: 3 loud blocks, 2 quiet, at 100 ms a block."""
    return [loud if i % 5 < 3 else quiet for i in range(int(sec * 10))]


def _feed(sentinel, levels, threshold=0.02, t0=0.0):
    tripped_at = None
    for i, rms in enumerate(levels):
        at = t0 + (i + 1) * 0.1
        if sentinel.feed(at, 0.1, rms, threshold) and tripped_at is None:
            tripped_at = at
    return tripped_at


def test_a_meeting_trips_the_sentinel_within_a_minute_and_a_half():
    at = _feed(ba.VoiceSentinel(), _speech_levels(120))
    assert at is not None and at < 90


def test_one_sentence_to_a_colleague_does_not():
    levels = [0.001] * 300 + _speech_levels(10) + [0.001] * 900
    assert _feed(ba.VoiceSentinel(), levels) is None


def test_a_plane_engine_never_trips_it_however_loud():
    """Steady noise lifts the floor with it: nothing stands ×2 above itself."""
    rng = np.random.default_rng(1)
    levels = list(0.3 * (1 + 0.15 * rng.standard_normal(20 * 60 * 10)))  # 20 min
    assert _feed(ba.VoiceSentinel(), levels) is None


def test_people_talking_on_the_plane_still_do():
    rng = np.random.default_rng(2)
    noise = 0.05 * (1 + 0.15 * rng.standard_normal(1200))
    speech = _speech_levels(120, loud=0.25, quiet=0.0)
    levels = [max(n, s) for n, s in zip(noise, speech)]
    assert _feed(ba.VoiceSentinel(), levels) is not None


def test_nothing_counts_before_the_floor_is_known():
    s = ba.VoiceSentinel(need_sec=0.5)
    assert _feed(s, [0.5] * 50) is None  # 5 s: no floor yet


# ── 👂 SessionRecorder listening: memory only, until record() ───────────────
def test_listening_writes_nothing_then_record_keeps_the_minutes_before(tmp_path):
    woke = []
    rec = ba.SessionRecorder(tmp_path, "Victor", listening=True, ring_sec=60,
                             sentinel=ba.VoiceSentinel(need_sec=3, window_sec=20),
                             on_wake=woke.append)
    t0 = datetime(2026, 11, 24, 12, 40, 0).timestamp()
    levels = [0.001] * 150 + _speech_levels(10)
    for i, amp in enumerate(levels):
        rec.write(_tone(0.1, amp), "DJI", 0.02, at=t0 + (i + 1) * 0.1)
    assert _wait(lambda: woke == ["Victor"])
    assert list(tmp_path.glob("*.pcm")) == [], "listening never touches the disk"
    rec.record()
    for i in range(10):  # and on it goes, after the wake
        rec.write(_tone(0.1), "DJI", 0.02, at=t0 + (len(levels) + i + 1) * 0.1)
    rec.stop()
    pcms = list(tmp_path.glob("*.pcm"))
    assert [p.name for p in pcms] == ["2026-11-24T12-40-00.000-Victor.s16le16k.pcm"], \
        "the ring starts the file at its own first sample, the minute it was spoken"
    assert pcms[0].stat().st_size == (len(levels) + 10) * BLOCK * 2


def test_the_ring_forgets_what_is_older_than_ring_sec(tmp_path):
    rec = ba.SessionRecorder(tmp_path, "Victor", listening=True, ring_sec=2)
    t0 = datetime(2026, 11, 24, 12, 0, 0).timestamp()
    for i in range(50):
        rec.write(_tone(0.1, 0.001), "DJI", 0.02, at=t0 + (i + 1) * 0.1)
    assert _wait(lambda: rec._q.empty())
    rec.record()
    rec.stop()
    pcms = list(tmp_path.glob("*.pcm"))
    assert len(pcms) == 1 and pcms[0].stat().st_size == 20 * BLOCK * 2
