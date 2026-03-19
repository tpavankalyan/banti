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


import json
import os
from unittest.mock import patch, MagicMock, AsyncMock
from httpx import AsyncClient, ASGITransport


def _make_mock_openai_stream(tokens: list[str]):
    """Fake AsyncOpenAI streaming response yielding token chunks."""
    class FakeDelta:
        def __init__(self, content): self.content = content
    class FakeChoice:
        def __init__(self, content): self.delta = FakeDelta(content)
    class FakeChunk:
        def __init__(self, content): self.choices = [FakeChoice(content)]
    class FakeStream:
        def __init__(self, tokens): self._tokens = iter(tokens)
        def __aiter__(self): return self
        async def __anext__(self):
            try: return FakeChunk(next(self._tokens))
            except StopIteration: raise StopAsyncIteration
    return FakeStream(tokens)


async def _collect_sse(client, body: dict) -> list[dict]:
    events = []
    async with client.stream("POST", "/brain/stream", json=body) as resp:
        async for line in resp.aiter_lines():
            if line.startswith("data: "):
                events.append(json.loads(line[6:]))
    return events


async def test_brain_stream_returns_sse_content_type(app):
    with patch.dict(os.environ, {"CEREBRAS_API_KEY": "fake"}):
        with patch("memory.AsyncOpenAI") as mock_cls:
            mock_cls.return_value.chat.completions.create = AsyncMock(
                return_value=_make_mock_openai_stream(["[silent]"])
            )
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                async with client.stream("POST", "/brain/stream", json={
                    "track": "reflex", "snapshot_json": "{}", "recent_speech": []
                }) as resp:
                    assert resp.status_code == 200
                    assert "text/event-stream" in resp.headers["content-type"]


async def test_brain_stream_reflex_emits_error_when_no_cerebras_key(app):
    env = {k: v for k, v in os.environ.items() if k != "CEREBRAS_API_KEY"}
    with patch.dict(os.environ, env, clear=True):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            events = await _collect_sse(client, {
                "track": "reflex", "snapshot_json": "{}", "recent_speech": []
            })
    types = [e["type"] for e in events]
    assert "error" in types


async def test_brain_stream_reflex_emits_sentences(app):
    tokens = ["I see you have been ", "working hard. ", "Let me help you out!"]
    with patch.dict(os.environ, {"CEREBRAS_API_KEY": "fake"}):
        with patch("memory.AsyncOpenAI") as mock_cls:
            mock_cls.return_value.chat.completions.create = AsyncMock(
                return_value=_make_mock_openai_stream(tokens)
            )
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                events = await _collect_sse(client, {
                    "track": "reflex", "snapshot_json": "{}", "recent_speech": []
                })
    sentence_events = [e for e in events if e["type"] == "sentence"]
    assert len(sentence_events) >= 1
    assert events[-1]["type"] == "done"


async def test_brain_stream_reflex_emits_silent_for_silent_response(app):
    with patch.dict(os.environ, {"CEREBRAS_API_KEY": "fake"}):
        with patch("memory.AsyncOpenAI") as mock_cls:
            mock_cls.return_value.chat.completions.create = AsyncMock(
                return_value=_make_mock_openai_stream(["[silent]"])
            )
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                events = await _collect_sse(client, {
                    "track": "reflex", "snapshot_json": "{}", "recent_speech": []
                })
    types = [e["type"] for e in events]
    assert "silent" in types
    assert "sentence" not in types
    assert events[-1]["type"] == "done"
