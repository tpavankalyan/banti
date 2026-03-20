# memory_sidecar/tests/test_brain_stream.py
import pytest
from models import BrainStreamRequest, ConversationTurn


class TestBrainStreamRequest:

    def test_accepts_conversation_history(self):
        req = BrainStreamRequest(
            track="reflex",
            ambient_context='{"face": {}}',
            conversation_history=[
                ConversationTurn(speaker="human", text="hello banti", timestamp=1000.0),
                ConversationTurn(speaker="banti", text="hi there", timestamp=1001.0),
            ],
        )
        assert len(req.conversation_history) == 2
        assert req.conversation_history[0].speaker == "human"

    def test_ambient_context_defaults_to_empty_object(self):
        req = BrainStreamRequest(track="reflex")
        assert req.ambient_context == "{}"

    def test_conversation_history_defaults_to_empty(self):
        req = BrainStreamRequest(track="reflex")
        assert req.conversation_history == []

    def test_last_banti_utterance_defaults_to_none(self):
        req = BrainStreamRequest(track="reflex")
        assert req.last_banti_utterance is None

    def test_old_snapshot_json_field_does_not_exist(self):
        req = BrainStreamRequest(track="reflex")
        assert not hasattr(req, "snapshot_json")

    def test_old_recent_speech_field_does_not_exist(self):
        req = BrainStreamRequest(track="reflex")
        assert not hasattr(req, "recent_speech")


class TestFormatConversation:
    """Tests for the _format_conversation helper used in prompt assembly."""

    def test_empty_history_returns_placeholder(self):
        from memory import _format_conversation
        result = _format_conversation([])
        assert result == "(no conversation yet)"

    def test_human_turn_prefixed_correctly(self):
        from memory import _format_conversation
        turn = ConversationTurn(speaker="human", text="hello", timestamp=1000.0)
        result = _format_conversation([turn])
        assert result == "Human: hello"

    def test_banti_turn_prefixed_correctly(self):
        from memory import _format_conversation
        turn = ConversationTurn(speaker="banti", text="hi there", timestamp=1001.0)
        result = _format_conversation([turn])
        assert result == "Banti: hi there"

    def test_mixed_turns_in_order(self):
        from memory import _format_conversation
        turns = [
            ConversationTurn(speaker="human", text="hello", timestamp=1000.0),
            ConversationTurn(speaker="banti", text="hi", timestamp=1001.0),
            ConversationTurn(speaker="human", text="how are you", timestamp=1002.0),
        ]
        result = _format_conversation(turns)
        assert result == "Human: hello\nBanti: hi\nHuman: how are you"


import json
import os
from unittest.mock import patch, MagicMock, AsyncMock
from httpx import AsyncClient, ASGITransport
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
                    "track": "reflex", "ambient_context": "{}", "conversation_history": []
                }) as resp:
                    assert resp.status_code == 200
                    assert "text/event-stream" in resp.headers["content-type"]


async def test_brain_stream_reflex_emits_error_when_no_cerebras_key(app):
    env = {k: v for k, v in os.environ.items() if k != "CEREBRAS_API_KEY"}
    with patch.dict(os.environ, env, clear=True):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            events = await _collect_sse(client, {
                "track": "reflex", "ambient_context": "{}", "conversation_history": []
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
                    "track": "reflex", "ambient_context": "{}", "conversation_history": []
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
                    "track": "reflex", "ambient_context": "{}", "conversation_history": []
                })
    types = [e["type"] for e in events]
    assert "silent" in types
    assert "sentence" not in types
    assert events[-1]["type"] == "done"


async def test_brain_stream_reasoning_emits_sentences(app):
    """Reasoning track uses AsyncAnthropic Opus; mock text_stream and verify sentence events."""
    mock_text = "I remember you mentioned this bug before. It was related to threading issues."

    async def fake_text_stream():
        for token in mock_text.split(" "):
            yield token + " "

    class FakeAsyncStream:
        """Mimics anthropic.AsyncAnthropic().messages.stream() async context manager."""
        async def __aenter__(self):
            return self
        async def __aexit__(self, *a):
            pass
        @property
        def text_stream(self):
            return fake_text_stream()

    with patch("memory.anthropic") as mock_anthropic:
        mock_anthropic.AsyncAnthropic.return_value.messages.stream.return_value = FakeAsyncStream()
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "fake"}):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                events = await _collect_sse(client, {
                    "track": "reasoning",
                    "ambient_context": "{}",
                    "conversation_history": [],
                })

    types = [e["type"] for e in events]
    assert "sentence" in types, f"Expected sentence events but got: {types}"
    assert events[-1]["type"] == "done"
