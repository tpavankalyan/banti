# memory_sidecar/tests/test_brain_stream.py
import pytest
from models import BrainStreamRequest

def test_brain_stream_request_defaults():
    req = BrainStreamRequest(track="reflex", snapshot_json="{}")
    assert req.track == "reflex"
    assert req.recent_speech == []
    assert req.last_spoke_seconds_ago == 9999.0
    assert req.last_spoke_text is None

def test_brain_stream_request_reasoning_track():
    req = BrainStreamRequest(track="reasoning", snapshot_json="{}")
    assert req.track == "reasoning"
