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


from memory import extract_sentences

def test_extract_sentences_emits_long_sentences():
    sentences, remaining = extract_sentences(
        "I see you have been working hard. Let me help you right now!"
    )
    assert sentences == ["I see you have been working hard.", "Let me help you right now!"]
    assert remaining == ""

def test_extract_sentences_keeps_short_sentence_in_buffer():
    # "Ok." = 1 word < 4 — should NOT split here; whole segment emits at next boundary
    sentences, remaining = extract_sentences("Ok. That is really interesting to me.")
    assert sentences == ["Ok. That is really interesting to me."]
    assert remaining == ""

def test_extract_sentences_incomplete_stays_in_buffer():
    sentences, remaining = extract_sentences("I am thinking about")
    assert sentences == []
    assert remaining == "I am thinking about"

def test_extract_sentences_empty_input():
    sentences, remaining = extract_sentences("")
    assert sentences == []
    assert remaining == ""

def test_extract_sentences_question_mark_boundary():
    sentences, remaining = extract_sentences("Have you tried running the tests? That might help.")
    assert "Have you tried running the tests?" in sentences
