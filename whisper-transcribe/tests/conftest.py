"""Make `import whisper_runner` work regardless of where pytest was started.

`whisper-transcribe` is a plain directory of scripts, not an installed package,
so the tests could only ever import the runner because `python -m pytest` happens
to put the working directory on `sys.path`. That made the suite depend on being
invoked from exactly one place — and it broke the moment it wasn't.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


import pytest


@pytest.fixture(autouse=True)
def _no_real_meeting_marker(tmp_path, monkeypatch):
    """A real call on this Mac must not leak into the tests via ~/.victor-addons/in-call."""
    import whisper_runner

    monkeypatch.setattr(whisper_runner, "_IN_CALL_MARKER", tmp_path / "no-such-in-call")
