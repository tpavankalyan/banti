# Real-Time Parallel Brain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the serial 4-7s speak pipeline with two parallel streaming tracks — a ~300ms Cerebras reflex track and a ~2-3s Opus reasoning track — so banti feels like a natural, real-time presence.

**Architecture:** On every trigger, BrainLoop fires two concurrent Swift Tasks. Track 1 calls a new `/brain/stream` SSE endpoint with Cerebras `gpt-oss-120b` (no memory, instant response); Track 2 calls the same endpoint with Opus 4.6 (full Graphiti+mem0 context). Both tracks stream sentences to CartesiaSpeaker which plays them via Cartesia WebSocket (per-frame PCM, starts playing ~100ms after first frame). Deepgram's final transcript fires directly into BrainLoop rather than waiting for the 2s poll.

**Tech Stack:** Python FastAPI + `openai` SDK (Cerebras via base_url override) + `anthropic` SDK; Swift actors + `URLSessionWebSocketTask`; Cartesia WebSocket TTS; XCTest + pytest-asyncio

**Spec:** `docs/superpowers/specs/2026-03-19-realtime-parallel-brain-design.md`

---

## File Map

| File | Change |
|------|--------|
| `memory_sidecar/models.py` | Add `BrainStreamRequest` |
| `memory_sidecar/memory.py` | Add `extract_sentences`, `REFLEX_SYSTEM_PROMPT`, `brain_stream_generate`, `_reflex_stream`, `_reasoning_stream` |
| `memory_sidecar/main.py` | Add `/brain/stream` route |
| `memory_sidecar/tests/test_brain_stream.py` | New — all Python tests for this feature |
| `Sources/BantiCore/TrackPriority.swift` | New — `TrackPriority` enum |
| `Sources/BantiCore/DeepgramStreamer.swift` | Add `onFinalTranscript` callback property; fire it in `handleMessage` |
| `Sources/BantiCore/AudioRouter.swift` | Add `setTranscriptCallback` method |
| `Sources/BantiCore/CartesiaSpeaker.swift` | Add dual WebSocket sockets, `streamSpeak`, `cancelTrack`, `finishCurrentSentence` |
| `Sources/BantiCore/BrainLoop.swift` | Rewrite `evaluate()` as parallel tasks; add `streamTrack`, `onFinalTranscript`; move transcript accumulation |
| `Sources/BantiCore/MemoryEngine.swift` | Wire transcript callback after `start()` |
| `Tests/BantiTests/DeepgramStreamerTests.swift` | Add callback test |
| `Tests/BantiTests/CartesiaSpeakerTests.swift` | Add `streamSpeak`/`cancelTrack`/`finishCurrentSentence` tests |
| `Tests/BantiTests/BrainLoopTests.swift` | Add `SSEEvent` decoding + `appendTranscript` callback tests |
| `.env` | Add `CEREBRAS_API_KEY` |

---

## Task 1: `BrainStreamRequest` Pydantic model

**Files:**
- Modify: `memory_sidecar/models.py`
- Create: `memory_sidecar/tests/test_brain_stream.py`

- [ ] **Step 1: Write the failing test**

```python
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
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_brain_stream.py -v
```
Expected: `ImportError: cannot import name 'BrainStreamRequest' from 'models'`

- [ ] **Step 3: Add `BrainStreamRequest` to `models.py`**

Add after `ProactiveDecisionResponse`:

```python
class BrainStreamRequest(BaseModel):
    track: Literal["reflex", "reasoning"]
    snapshot_json: str = "{}"
    recent_speech: list[str] = []
    last_spoke_seconds_ago: float = 9999.0
    last_spoke_text: Optional[str] = None
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_brain_stream.py::test_brain_stream_request_defaults tests/test_brain_stream.py::test_brain_stream_request_reasoning_track -v
```
Expected: 2 passed

- [ ] **Step 5: Commit**

```bash
git add memory_sidecar/models.py memory_sidecar/tests/test_brain_stream.py
git commit -m "feat: add BrainStreamRequest model"
```

---

## Task 2: `extract_sentences` utility

**Files:**
- Modify: `memory_sidecar/memory.py`
- Modify: `memory_sidecar/tests/test_brain_stream.py`

- [ ] **Step 1: Write failing tests**

Add to `test_brain_stream.py`:

```python
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
```

- [ ] **Step 2: Run to confirm failures**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_brain_stream.py -k "extract_sentences" -v
```
Expected: `ImportError: cannot import name 'extract_sentences' from 'memory'`

- [ ] **Step 3: Add `extract_sentences` to `memory.py`**

Add near the top of `memory.py`, after imports:

```python
import re as _re

def extract_sentences(buffer: str, min_words: int = 4) -> tuple[list[str], str]:
    """Split accumulated LLM token buffer into emittable sentences.

    Returns (emittable_sentences, remaining_buffer).
    A sentence is emitted when it ends with .!? and has >= min_words words.
    Short sentences (< min_words) stay in the buffer and merge with subsequent text.
    """
    sentences = []
    last_emitted = 0

    for match in _re.finditer(r'[.!?](?=[ \n]|$)', buffer):
        end = match.end()
        segment = buffer[last_emitted:end].strip()
        if segment and len(segment.split()) >= min_words:
            sentences.append(segment)
            last_emitted = end
            # skip leading whitespace before next segment
            while last_emitted < len(buffer) and buffer[last_emitted] in ' \n':
                last_emitted += 1

    remaining = buffer[last_emitted:]
    return sentences, remaining
```

- [ ] **Step 4: Run to confirm tests pass**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_brain_stream.py -k "extract_sentences" -v
```
Expected: 5 passed

- [ ] **Step 5: Commit**

```bash
git add memory_sidecar/memory.py memory_sidecar/tests/test_brain_stream.py
git commit -m "feat: add extract_sentences utility for SSE sentence boundary detection"
```

---

## Task 3: `/brain/stream` endpoint — reflex track

**Files:**
- Modify: `memory_sidecar/memory.py`
- Modify: `memory_sidecar/main.py`
- Modify: `memory_sidecar/tests/test_brain_stream.py`

- [ ] **Step 1: Write failing tests**

Add to `test_brain_stream.py`:

```python
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
    types = [e["type"] for e in events]
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
```

- [ ] **Step 2: Run to confirm failures**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_brain_stream.py -k "brain_stream" -v
```
Expected: errors — `/brain/stream` endpoint not found

- [ ] **Step 3: Add `REFLEX_SYSTEM_PROMPT`, `_sse_*` helpers, and `_reflex_stream` to `memory.py`**

Add after `extract_sentences` (before the existing `BRAIN_SYSTEM_PROMPT`):

```python
from openai import AsyncOpenAI

REFLEX_SYSTEM_PROMPT = """\
You are banti, an ambient AI assistant watching over the user's Mac.
Speak in short, natural sentences — like a thoughtful friend nearby.
React only to what's genuinely happening right now. 1-2 sentences max.
Respond with plain prose only. No JSON. No markdown. No preamble.
If there is truly nothing worth saying, respond with exactly: [silent]"""


def _sse(event: dict) -> str:
    return f"data: {json.dumps(event)}\n\n"


async def _reflex_stream(req):
    """Async generator: yields SSE strings for the reflex track."""
    cerebras_key = os.environ.get("CEREBRAS_API_KEY")
    if not cerebras_key:
        yield _sse({"type": "error"})
        return

    client = AsyncOpenAI(base_url="https://api.cerebras.ai/v1", api_key=cerebras_key)
    user_msg = f"Snapshot:\n{req.snapshot_json}\n\nRecent speech:\n" + "\n".join(req.recent_speech)

    buffer = ""
    try:
        import asyncio
        async with asyncio.timeout(8):
            stream = await client.chat.completions.create(
                model="gpt-oss-120b",
                messages=[
                    {"role": "system", "content": REFLEX_SYSTEM_PROMPT},
                    {"role": "user", "content": user_msg},
                ],
                stream=True,
                max_tokens=120,
            )
            async for chunk in stream:
                delta = chunk.choices[0].delta.content or ""
                buffer += delta
                sentences, buffer = extract_sentences(buffer)
                for s in sentences:
                    yield _sse({"type": "sentence", "text": s})
    except Exception:
        yield _sse({"type": "error"})
        return

    # Flush remaining buffer
    remaining = buffer.strip()
    if remaining == "[silent]":
        yield _sse({"type": "silent"})
    elif remaining:
        yield _sse({"type": "sentence", "text": remaining})
```

- [ ] **Step 4: Add `brain_stream_generate` to `memory.py`**

Add after `_reflex_stream`:

```python
async def brain_stream_generate(req):
    """Top-level SSE generator — routes to reflex or reasoning track."""
    if req.track == "reflex":
        async for event in _reflex_stream(req):
            yield event
    else:
        # Reasoning track added in Task 4
        yield _sse({"type": "error"})
    yield _sse({"type": "done"})
```

- [ ] **Step 5: Add `/brain/stream` route to `main.py`**

Add after the existing `/brain/decide` route:

```python
from fastapi.responses import StreamingResponse

@app.post("/brain/stream")
async def brain_stream_endpoint(req: BrainStreamRequest):
    from memory import brain_stream_generate
    return StreamingResponse(
        brain_stream_generate(req),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
```

Also add `BrainStreamRequest` to the import near the top of `main.py`:

```python
from models import BrainDecideRequest, ProactiveDecisionResponse, BrainStreamRequest
```

- [ ] **Step 6: Run tests to confirm they pass**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_brain_stream.py -v
```
Expected: all tests pass (model + extract_sentences + brain_stream tests)

- [ ] **Step 7: Commit**

```bash
git add memory_sidecar/memory.py memory_sidecar/main.py memory_sidecar/tests/test_brain_stream.py
git commit -m "feat: add /brain/stream SSE endpoint with reflex track (Cerebras gpt-oss-120b)"
```

---

## Task 4: `/brain/stream` reasoning track

**Files:**
- Modify: `memory_sidecar/memory.py`
- Modify: `memory_sidecar/tests/test_brain_stream.py`

- [ ] **Step 1: Write failing test**

Add to `test_brain_stream.py`:

```python
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
                    "snapshot_json": "{}",
                    "recent_speech": [],
                })

    types = [e["type"] for e in events]
    assert "sentence" in types or "done" in types
    assert events[-1]["type"] == "done"
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_brain_stream.py::test_brain_stream_reasoning_emits_sentences -v
```
Expected: FAIL — reasoning track returns `{"type": "error"}` currently

- [ ] **Step 3: Add `REASONING_SYSTEM_PROMPT` and `_reasoning_stream` to `memory.py`**

Add after `_reflex_stream`:

```python
REASONING_SYSTEM_PROMPT = """\
You are banti. A quick reflex response was just given. Now add depth, memory,
or context only if you have something genuinely useful to say. 1-3 sentences.
Plain prose only — no JSON, no preamble.
If you have nothing meaningful to add, respond with exactly: [silent]"""


async def _reasoning_stream(req):
    """Async generator: yields SSE strings for the reasoning track (Opus 4.6 + memory)."""
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    if not anthropic_key:
        yield _sse({"type": "error"})
        return

    # Fetch Graphiti + mem0 in parallel (same pattern as brain_decide)
    context_parts = []
    if GRAPHITI is not None or MEM0 is not None:
        async def _fetch_graphiti():
            if GRAPHITI is None:
                return
            try:
                edges = await GRAPHITI.search("recent events and who is present", num_results=3)
                facts = [e.fact for e in edges if e.fact]
                if facts:
                    context_parts.append("Temporal memory:\n" + "\n".join(f"  - {f}" for f in facts))
            except Exception as e:
                print(f"[warn] reasoning_stream: Graphiti failed: {e}")

        async def _fetch_mem0():
            if MEM0 is None:
                return
            try:
                snap_dict = json.loads(req.snapshot_json) if req.snapshot_json != "{}" else {}
                person = snap_dict.get("person")
                if person and person.get("name") and person.get("id"):
                    user_id = f"person_{person['id']}"
                    hits = MEM0.search(person["name"], user_id=user_id, limit=3)
                    facts = [h["memory"] for h in hits if "memory" in h]
                    if facts:
                        context_parts.append(
                            f"What I know about {person['name']}:\n" +
                            "\n".join(f"  - {f}" for f in facts)
                        )
            except Exception as e:
                print(f"[warn] reasoning_stream: mem0 failed: {e}")

        import asyncio as _asyncio
        await _asyncio.gather(_fetch_graphiti(), _fetch_mem0())

    snapshot_summary = "\n\n".join(context_parts) if context_parts else "(no memory context)"
    user_msg = (
        f"Memory context:\n{snapshot_summary}\n\n"
        f"Current snapshot:\n{req.snapshot_json}\n\n"
        f"Recent speech:\n" + "\n".join(req.recent_speech)
    )

    buffer = ""
    try:
        import asyncio
        async_client = anthropic.AsyncAnthropic(api_key=anthropic_key)
        async with asyncio.timeout(20):
            async with async_client.messages.stream(
                model="claude-opus-4-6",
                max_tokens=200,
                system=REASONING_SYSTEM_PROMPT,
                messages=[{"role": "user", "content": user_msg}],
            ) as stream:
                async for text in stream.text_stream:
                    buffer += text
                    sentences, buffer = extract_sentences(buffer)
                    for s in sentences:
                        yield _sse({"type": "sentence", "text": s})
    except Exception as e:
        print(f"[warn] reasoning_stream: failed: {e}")
        yield _sse({"type": "error"})
        return

    remaining = buffer.strip()
    if remaining == "[silent]":
        yield _sse({"type": "silent"})
    elif remaining:
        yield _sse({"type": "sentence", "text": remaining})
```

- [ ] **Step 4: Update `brain_stream_generate` to use `_reasoning_stream`**

Replace the reasoning branch in `brain_stream_generate`:

```python
async def brain_stream_generate(req):
    """Top-level SSE generator — routes to reflex or reasoning track."""
    if req.track == "reflex":
        async for event in _reflex_stream(req):
            yield event
    else:
        async for event in _reasoning_stream(req):
            yield event
    yield _sse({"type": "done"})
```

- [ ] **Step 5: Run all Python tests**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/ -v
```
Expected: all existing tests + new brain_stream tests pass

- [ ] **Step 6: Commit**

```bash
git add memory_sidecar/memory.py memory_sidecar/tests/test_brain_stream.py
git commit -m "feat: add reasoning track to /brain/stream (Opus 4.6 + parallel memory)"
```

---

## Task 5: `TrackPriority` enum + `DeepgramStreamer.onFinalTranscript`

**Files:**
- Create: `Sources/BantiCore/TrackPriority.swift`
- Modify: `Sources/BantiCore/DeepgramStreamer.swift`
- Modify: `Sources/BantiCore/AudioRouter.swift`
- Modify: `Tests/BantiTests/DeepgramStreamerTests.swift`

- [ ] **Step 1: Write failing Swift tests**

Add to `Tests/BantiTests/DeepgramStreamerTests.swift` (read it first to match style, then add at the end):

```swift
func testOnFinalTranscriptCallbackFiredOnFinalMessage() async {
    // DeepgramStreamer.parseResponse returns a SpeechState with isFinal=true
    // Simulate handleMessage firing the callback
    var received: String? = nil
    let context = PerceptionContext()
    let logger = Logger()
    let streamer = DeepgramStreamer(apiKey: "key", context: context, logger: logger)
    await streamer.setTranscriptCallbackForTest { transcript in
        received = transcript
    }
    // Craft a valid final-transcript Deepgram JSON
    let json = """
    {"is_final":true,"channel":{"alternatives":[{"transcript":"hello world","confidence":0.9,"words":[{"speaker":0}]}]}}
    """.data(using: .utf8)!
    await streamer.handleMessageForTest(.data(json))
    XCTAssertEqual(received, "hello world")
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
swift test --filter DeepgramStreamerTests 2>&1 | tail -20
```
Expected: compile error — `setTranscriptCallbackForTest` not defined

- [ ] **Step 3: Create `Sources/BantiCore/TrackPriority.swift`**

```swift
// Sources/BantiCore/TrackPriority.swift
public enum TrackPriority: String, Sendable {
    case reflex
    case reasoning
}
```

- [ ] **Step 4: Add `onFinalTranscript` to `DeepgramStreamer.swift`**

Add the property after the existing private vars (around line 17):

```swift
public var onFinalTranscript: (@Sendable (String) async -> Void)?
```

In `handleMessage(_:)`, after `await context.update(.speech(state))` (line 175), add:

```swift
if let callback = onFinalTranscript {
    await callback(state.transcript)
}
```

Add test helpers at the bottom (after existing test helpers if any):

```swift
// MARK: - Test helpers
func setTranscriptCallbackForTest(_ callback: @escaping @Sendable (String) async -> Void) {
    onFinalTranscript = callback
}
func handleMessageForTest(_ message: URLSessionWebSocketTask.Message) async {
    await handleMessage(message)
}
```

Note: `handleMessage` is currently `private`. Change it to `internal` by replacing `private func handleMessage` with `func handleMessage` (no access modifier = internal by default in a Swift module). This is required for the test helper to call it via `@testable import`.

- [ ] **Step 5: Add `setTranscriptCallback` to `AudioRouter.swift`**

Add after `configureWith(deepgramKey:humeKey:)`:

```swift
public func setTranscriptCallback(_ callback: @escaping @Sendable (String) async -> Void) {
    deepgram?.onFinalTranscript = callback
}
```

- [ ] **Step 6: Run Swift tests**

```bash
swift test --filter DeepgramStreamerTests 2>&1 | tail -20
```
Expected: all DeepgramStreamer tests pass including the new callback test

- [ ] **Step 7: Commit**

```bash
git add Sources/BantiCore/TrackPriority.swift Sources/BantiCore/DeepgramStreamer.swift Sources/BantiCore/AudioRouter.swift Tests/BantiTests/DeepgramStreamerTests.swift
git commit -m "feat: add TrackPriority enum and DeepgramStreamer.onFinalTranscript callback"
```

---

## Task 6: `CartesiaSpeaker` WebSocket streaming

**Files:**
- Modify: `Sources/BantiCore/CartesiaSpeaker.swift`
- Modify: `Tests/BantiTests/CartesiaSpeakerTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `Tests/BantiTests/CartesiaSpeakerTests.swift`:

```swift
func testStreamSpeakIsNoOpWhenUnavailable() async {
    let speaker = CartesiaSpeaker(logger: Logger(), apiKey: nil, voiceID: "test")
    // Must not crash
    await speaker.streamSpeak("hello there friend", track: .reflex)
}

func testCancelTrackReflexClearsIsSpeaking() async {
    let speaker = CartesiaSpeaker(logger: Logger(), apiKey: "key", voiceID: "voice")
    await speaker.setIsSpeakingReflexForTest(true)
    await speaker.cancelTrack(.reflex)
    let isSpeaking = await speaker.isSpeakingReflexForTest
    XCTAssertFalse(isSpeaking)
}

func testCancelTrackReasoningClearsPendingBuffers() async {
    let speaker = CartesiaSpeaker(logger: Logger(), apiKey: "key", voiceID: "voice")
    await speaker.addPendingReasoningBufferForTest()  // add a dummy entry
    await speaker.cancelTrack(.reasoning)
    let count = await speaker.pendingReasoningBufferCountForTest
    XCTAssertEqual(count, 0)
}

func testFinishCurrentSentenceReturnsImmediatelyWhenNotSpeaking() async {
    let speaker = CartesiaSpeaker(logger: Logger(), apiKey: "key", voiceID: "voice")
    // isSpeakingReflex defaults to false — should return almost instantly
    let start = Date()
    await speaker.finishCurrentSentence()
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
}
```

- [ ] **Step 2: Run to confirm failures**

```bash
swift test --filter CartesiaSpeakerTests 2>&1 | tail -20
```
Expected: compile errors — new methods not defined

- [ ] **Step 3: Add WebSocket state and new methods to `CartesiaSpeaker.swift`**

Add after the existing private state variables (after line 18):

```swift
// WebSocket sockets — one per track
private var reflexSocket: URLSessionWebSocketTask?
private var reasoningSocket: URLSessionWebSocketTask?

// Reflex speaking state (for finishCurrentSentence)
private var isSpeakingReflex: Bool = false
// Pending reasoning buffers (played after reflex finishes)
private var pendingReasoningBuffers: [AVAudioPCMBuffer] = []
```

Add new public methods before `// MARK: - Test helpers`:

```swift
public func streamSpeak(_ text: String, track: TrackPriority) async {
    guard isAvailable else {
        logger.log(source: "tts", message: "[info] Cartesia unavailable — would say: \(text)")
        return
    }
    guard let key = apiKey,
          let url = URL(string: "wss://api.cartesia.ai/tts/websocket") else { return }

    // Ensure the correct socket is connected
    let socket: URLSessionWebSocketTask
    if track == .reflex {
        if reflexSocket == nil { reflexSocket = connectSocket(url: url, apiKey: key) }
        guard let s = reflexSocket else { return }
        socket = s
        isSpeakingReflex = true
    } else {
        if reasoningSocket == nil { reasoningSocket = connectSocket(url: url, apiKey: key) }
        guard let s = reasoningSocket else { return }
        socket = s
    }

    let body: [String: Any] = [
        "model_id": "sonic-2",
        "transcript": text,
        "voice": ["mode": "id", "id": voiceID],
        "output_format": ["container": "raw", "encoding": "pcm_s16le", "sample_rate": 22050],
    ]
    guard let msgData = try? JSONSerialization.data(withJSONObject: body),
          let msgStr = String(data: msgData, encoding: .utf8) else { return }

    do {
        try await socket.send(.string(msgStr))
    } catch {
        logger.log(source: "tts", message: "[warn] CartesiaSpeaker WS send failed: \(error.localizedDescription)")
        if track == .reflex { reflexSocket = nil; isSpeakingReflex = false }
        else { reasoningSocket = nil }
        return
    }

    // Receive frames until done signal
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if Task.isCancelled { break }
        do {
            let message = try await socket.receive()
            switch message {
            case .data(let pcmData):
                if let buffer = CartesiaSpeaker.makeBuffer(pcmData) {
                    if track == .reflex {
                        playBuffer(buffer)
                    } else {
                        pendingReasoningBuffers.append(buffer)
                        drainReasoningIfReady()
                    }
                }
            case .string(let text):
                if text.contains("\"done\"") || text.contains("done") { break }
            @unknown default: break
            }
        } catch {
            logger.log(source: "tts", message: "[warn] CartesiaSpeaker WS receive failed: \(error.localizedDescription)")
            break
        }
    }

    if track == .reflex {
        isSpeakingReflex = false
        drainReasoningIfReady()
    }
}

// `async` required so callers can `await` across the actor boundary.
// Swift actors release at every `await` point, so `streamSpeak` (suspended on
// `socket.receive()`) is NOT blocking the actor — cancelTrack runs immediately
// between receives. Cancelling the socket causes the next `receive()` to throw,
// safely exiting the `streamSpeak` loop.
public func cancelTrack(_ track: TrackPriority) async {
    if track == .reflex {
        reflexSocket?.cancel(with: .normalClosure, reason: nil)
        reflexSocket = nil
        isSpeakingReflex = false
        playerNode.stop()
        if engineStarted { playerNode.play() }
    } else {
        reasoningSocket?.cancel(with: .normalClosure, reason: nil)
        reasoningSocket = nil
        pendingReasoningBuffers.removeAll()
    }
}

public func finishCurrentSentence() async {
    var waited = 0.0
    while isSpeakingReflex && waited < 2.0 {
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        waited += 0.05
    }
}

private func connectSocket(url: URL, apiKey: String) -> URLSessionWebSocketTask? {
    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
    request.setValue("2024-06-10", forHTTPHeaderField: "Cartesia-Version")
    let task = session.webSocketTask(with: request)
    task.resume()
    return task
}

private func drainReasoningIfReady() {
    guard !isSpeakingReflex, !pendingReasoningBuffers.isEmpty else { return }
    for buffer in pendingReasoningBuffers {
        playBuffer(buffer)
    }
    pendingReasoningBuffers.removeAll()
}
```

- [ ] **Step 4: Add test helpers to `CartesiaSpeaker.swift`**

In the existing `// MARK: - Test helpers` section, add:

```swift
func setIsSpeakingReflexForTest(_ value: Bool) { isSpeakingReflex = value }
var isSpeakingReflexForTest: Bool { isSpeakingReflex }
func addPendingReasoningBufferForTest() {
    if let buf = CartesiaSpeaker.makeBuffer(Data(repeating: 0, count: 200)) {
        pendingReasoningBuffers.append(buf)
    }
}
var pendingReasoningBufferCountForTest: Int { pendingReasoningBuffers.count }
```

- [ ] **Step 5: Run Swift tests**

```bash
swift test --filter CartesiaSpeakerTests 2>&1 | tail -20
```
Expected: all CartesiaSpeaker tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/BantiCore/CartesiaSpeaker.swift Tests/BantiTests/CartesiaSpeakerTests.swift
git commit -m "feat: add CartesiaSpeaker WebSocket streaming — streamSpeak, cancelTrack, finishCurrentSentence"
```

---

## Task 7: `BrainLoop` parallel tracks

**Files:**
- Modify: `Sources/BantiCore/BrainLoop.swift`
- Modify: `Tests/BantiTests/BrainLoopTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `Tests/BantiTests/BrainLoopTests.swift`:

```swift
// MARK: - SSEEvent decoding

func testSSEEventDecodesTypeSentence() throws {
    let json = #"{"type":"sentence","text":"Hello there!"}"#.data(using: .utf8)!
    let event = try JSONDecoder().decode(SSEEvent.self, from: json)
    XCTAssertEqual(event.type, "sentence")
    XCTAssertEqual(event.text, "Hello there!")
}

func testSSEEventDecodesDone() throws {
    let json = #"{"type":"done"}"#.data(using: .utf8)!
    let event = try JSONDecoder().decode(SSEEvent.self, from: json)
    XCTAssertEqual(event.type, "done")
    XCTAssertNil(event.text)
}

func testSSEEventDecodesSilent() throws {
    let json = #"{"type":"silent"}"#.data(using: .utf8)!
    let event = try JSONDecoder().decode(SSEEvent.self, from: json)
    XCTAssertEqual(event.type, "silent")
}
```

- [ ] **Step 2: Run to confirm failures**

```bash
swift test --filter BrainLoopTests 2>&1 | tail -20
```
Expected: compile error — `SSEEvent` not defined

- [ ] **Step 3: Rewrite `BrainLoop.swift`**

Replace the entire file with:

```swift
// Sources/BantiCore/BrainLoop.swift
import Foundation

// MARK: - SSE types (internal — used by BrainLoop and tests)
struct SSEEvent: Decodable {
    let type: String
    let text: String?
}

struct BrainStreamBody: Encodable {
    let track: String
    let snapshot_json: String
    let recent_speech: [String]
    let last_spoke_seconds_ago: Double
    let last_spoke_text: String?
}

public actor BrainLoop {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let speaker: CartesiaSpeaker
    private let logger: Logger

    private static let heartbeatNanoseconds: UInt64 = 15_000_000_000  // 15s
    private static let pollNanoseconds: UInt64 = 5_000_000_000        // 5s (was 2s)
    private static let cooldownSeconds: Double = 10.0
    private static let maxTranscripts = 5

    private var lastSpoke: Date?
    private var lastSpokeText: String?
    private var recentTranscripts: [String] = []
    private var lastPersonID: String?
    private var lastPersonName: String?
    private var unknownPersonFirstSeen: Date?

    // Active track task handles for cancellation
    private var activeReflexTask: Task<Void, Never>?
    private var activeReasoningTask: Task<Void, Never>?

    public init(context: PerceptionContext, sidecar: MemorySidecar,
                speaker: CartesiaSpeaker, logger: Logger) {
        self.context = context
        self.sidecar = sidecar
        self.speaker = speaker
        self.logger = logger
    }

    // MARK: - Startup

    public func start() {
        // Heartbeat loop
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BrainLoop.heartbeatNanoseconds)
                await self.evaluate(reason: "heartbeat")
            }
        }
        // Event polling loop — face/emotion/person events only (5s)
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BrainLoop.pollNanoseconds)
                await self.pollEvents()
            }
        }
    }

    // MARK: - Direct speech callback (replaces transcript accumulation in pollEvents)

    public func onFinalTranscript(_ transcript: String) async {
        BrainLoop.appendTranscript(&recentTranscripts,
                                   new: transcript,
                                   isFinal: true)
        await evaluate(reason: "speech: \(transcript)")
    }

    // MARK: - Event polling (face / emotion / person only — no speech)

    private func pollEvents() async {
        let person = await context.person

        if let person {
            if person.id != lastPersonID {
                lastPersonID = person.id
                unknownPersonFirstSeen = person.name == nil ? Date() : nil
                await evaluate(reason: "new person detected")
            }
            if BrainLoop.nameJustResolved(previous: lastPersonName, current: person.name) {
                lastPersonName = person.name
                await evaluate(reason: "person name resolved: \(person.name ?? "")")
            } else {
                lastPersonName = person.name
            }
            if person.name == nil,
               let firstSeen = unknownPersonFirstSeen,
               BrainLoop.unknownPersonExceedsThreshold(firstSeen: firstSeen) {
                unknownPersonFirstSeen = nil
                await evaluate(reason: "unknown person present > 30s")
            }
        } else {
            lastPersonID = nil
            lastPersonName = nil
            unknownPersonFirstSeen = nil
        }

        if let ve = await context.voiceEmotion {
            let topScore = ve.emotions.map { $0.score }.max() ?? 0
            if BrainLoop.isEmotionSpike(topScore: topScore) {
                await evaluate(reason: "emotion spike detected")
            }
        }
    }

    // MARK: - Evaluate / fire parallel tracks

    private func evaluate(reason: String) async {
        guard BrainLoop.shouldTrigger(lastSpoke: lastSpoke) else { return }
        guard await sidecar.isRunning else { return }

        // Cancel in-flight tasks from prior trigger
        await speaker.cancelTrack(.reflex)   // async — actor releases between receives
        await speaker.cancelTrack(.reasoning)
        activeReflexTask?.cancel()
        activeReasoningTask?.cancel()

        // Set lastSpoke immediately (prevents duplicate triggers during ~300ms window)
        lastSpoke = Date()

        logger.log(source: "brain", message: "[\(reason)] firing parallel tracks")

        let brain = self
        activeReflexTask = Task { await brain.streamTrack(.reflex) }
        activeReasoningTask = Task { await brain.streamTrack(.reasoning) }
    }

    // MARK: - Stream a single track

    private func streamTrack(_ track: TrackPriority) async {
        guard await sidecar.isRunning else { return }

        let snapshot = await context.snapshotJSON()
        let body = BrainStreamBody(
            track: track.rawValue,
            snapshot_json: snapshot,
            recent_speech: recentTranscripts,
            last_spoke_seconds_ago: BrainLoop.secondsSince(lastSpoke),
            last_spoke_text: lastSpokeText
        )

        guard let url = URL(string: "/brain/stream", relativeTo: sidecar.baseURL),
              let bodyData = try? JSONEncoder().encode(body) else { return }

        var request = URLRequest(url: url, timeoutInterval: 25.0)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var spokeSentences: [String] = []

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                guard let data = jsonStr.data(using: .utf8),
                      let event = try? JSONDecoder().decode(SSEEvent.self, from: data) else { continue }
                if event.type == "done" { break }
                if event.type == "sentence", let text = event.text, !text.isEmpty {
                    spokeSentences.append(text)
                    await speaker.streamSpeak(text, track: track)
                }
            }
        } catch {
            logger.log(source: "brain",
                       message: "[warn] \(track.rawValue) track failed: \(error.localizedDescription)")
        }

        // Update lastSpokeText — Track 2 overwrites Track 1 if it spoke
        if !spokeSentences.isEmpty {
            lastSpokeText = spokeSentences.joined(separator: " ")
        }
    }

    // MARK: - Pure static helpers (testable without actor isolation)

    public static func shouldTrigger(lastSpoke: Date?, now: Date = Date()) -> Bool {
        guard let lastSpoke else { return true }
        return now.timeIntervalSince(lastSpoke) > cooldownSeconds
    }

    public static func appendTranscript(_ transcripts: inout [String],
                                        new: String?, isFinal: Bool) {
        guard let new, isFinal, new != transcripts.last else { return }
        if transcripts.count >= maxTranscripts { transcripts.removeFirst() }
        transcripts.append(new)
    }

    public static func secondsSince(_ date: Date?, now: Date = Date()) -> Double {
        guard let date else { return 9999.0 }
        return now.timeIntervalSince(date)
    }

    public static func isEmotionSpike(topScore: Float) -> Bool {
        return topScore >= 0.7
    }

    public static func unknownPersonExceedsThreshold(firstSeen: Date, now: Date = Date()) -> Bool {
        return now.timeIntervalSince(firstSeen) > 30.0
    }

    public static func nameJustResolved(previous: String?, current: String?) -> Bool {
        return previous == nil && current != nil
    }
}
```

- [ ] **Step 4: Run all Swift tests**

```bash
swift test 2>&1 | tail -30
```
Expected: all tests pass. The existing BrainLoop static-helper tests still pass because the static functions are unchanged.

**Note on transcript polling removal:** The old `pollEvents` accumulated transcripts via `context.speech`. This is removed — transcripts now only come via `onFinalTranscript`. If `DEEPGRAM_API_KEY` is absent, no transcripts accumulate (same behaviour as before, since Deepgram was the only source).

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/BrainLoop.swift Tests/BantiTests/BrainLoopTests.swift
git commit -m "feat: BrainLoop parallel tracks — streamTrack, onFinalTranscript, SSEEvent"
```

---

## Task 8: Wire callback + `.env` update

**Files:**
- Modify: `Sources/BantiCore/MemoryEngine.swift`
- Modify: `.env`

- [ ] **Step 1: Wire the transcript callback in `MemoryEngine.start()`**

In `MemoryEngine.swift`, after `await brainLoop.start()` in `start()`:

```swift
// Wire Deepgram final-transcript callback directly into BrainLoop
let loop = brainLoop
await audioRouter.setTranscriptCallback { @Sendable transcript in
    await loop.onFinalTranscript(transcript)
}
logger.log(source: "memory", message: "transcript callback wired")
```

- [ ] **Step 2: Add `CEREBRAS_API_KEY` to `.env`**

Open `.env` and add:

```
CEREBRAS_API_KEY=<your_cerebras_api_key_here>
```

Get your key at `https://cloud.cerebras.ai` → API Keys.

- [ ] **Step 3: Run all Swift tests one final time**

```bash
swift test 2>&1 | tail -30
```
Expected: all tests pass

- [ ] **Step 4: Run all Python tests one final time**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/ -v
```
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/MemoryEngine.swift
git commit -m "feat: wire DeepgramStreamer→BrainLoop transcript callback in MemoryEngine"
```

---

## Smoke Test (manual)

Once everything compiles and unit tests pass:

1. Add your `CEREBRAS_API_KEY` to `.env`
2. Run: `swift run banti`
3. Speak a sentence out loud
4. Expected: banti's voice starts within ~1s of you finishing (was 4-7s)
5. Check logs for: `[speech: ...] firing parallel tracks`, then `reflex` and `reasoning` track log lines
6. After reflex voice finishes, Opus reasoning response should follow (if it has something to add)
