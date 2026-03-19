# Proactive Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give banti a voice and a brain — Cartesia TTS for natural speech output, Claude Opus 4.6 for all reasoning decisions, and a BrainLoop actor that proactively speaks based on what it observes.

**Architecture:** The Python sidecar gains a `/brain/decide` endpoint that assembles full context (perception snapshot + Graphiti + mem0 + self.json), calls Opus 4.6, and returns a speak/silent decision. Swift's `BrainLoop` fires this on a 15s heartbeat and on perception events; when the decision is `speak`, it hands text to `CartesiaSpeaker`, which calls Cartesia's REST API and plays PCM via `AVAudioEngine`. Existing `query_memory` and `reflect_memory` are upgraded from GPT-4o to Opus 4.6.

**Tech Stack:** Python (FastAPI, Pydantic, `anthropic` SDK), Swift (async/await actors, `AVAudioEngine`, `URLSession`), Cartesia REST API (`tts/bytes`), Claude Opus 4.6 (`claude-opus-4-6`).

**Spec:** `docs/superpowers/specs/2026-03-19-proactive-assistant-design.md`

---

## File Map

| File | Change | Responsibility |
|---|---|---|
| `memory_sidecar/requirements.txt` | Modify | Add `anthropic~=0.40` |
| `memory_sidecar/models.py` | Modify | Add `BrainDecideRequest`, `ProactiveDecisionResponse` |
| `memory_sidecar/memory.py` | Modify | Add `brain_decide()`, upgrade `query_memory` + `reflect_memory` to Opus 4.6, add `import re` |
| `memory_sidecar/main.py` | Modify | Add `POST /brain/decide` route |
| `memory_sidecar/tests/test_memory.py` | Modify | Add tests for `brain_decide`, Opus upgrades |
| `Sources/BantiCore/MemoryTypes.swift` | Modify | Add `ProactiveDecision` Codable struct |
| `Sources/BantiCore/CartesiaSpeaker.swift` | Create | Cartesia HTTP → PCM → AVAudioEngine |
| `Sources/BantiCore/BrainLoop.swift` | Create | Heartbeat + event triggers + cooldown + sidecar call |
| `Sources/BantiCore/MemoryEngine.swift` | Modify | Own BrainLoop + CartesiaSpeaker, remove ProactiveIntroducer + startPersonObserver |
| `Tests/BantiTests/CartesiaSpeakerTests.swift` | Create | Tests for CartesiaSpeaker |
| `Tests/BantiTests/BrainLoopTests.swift` | Create | Tests for BrainLoop |
| `.env.example` | Modify | Add ANTHROPIC_API_KEY, CARTESIA_API_KEY, CARTESIA_VOICE_ID |

---

## Task 1: Add `anthropic` to Python dependencies

**Files:**
- Modify: `memory_sidecar/requirements.txt`

- [ ] **Step 1: Write the failing test**

Add to `memory_sidecar/tests/test_memory.py`:
```python
def test_anthropic_importable():
    import anthropic
    assert hasattr(anthropic, "AsyncAnthropic")
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_anthropic_importable -v
```
Expected: `FAILED` — `ModuleNotFoundError: No module named 'anthropic'`

- [ ] **Step 3: Add anthropic to requirements.txt**

Open `memory_sidecar/requirements.txt` and append:
```
anthropic~=0.40
```

- [ ] **Step 4: Install the package**

```bash
cd memory_sidecar && .venv/bin/pip install anthropic~=0.40
```
Expected: `Successfully installed anthropic-0.40.x`

- [ ] **Step 5: Run test to verify it passes**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_anthropic_importable -v
```
Expected: `1 passed`

- [ ] **Step 6: Commit**

```bash
git add memory_sidecar/requirements.txt
git commit -m "feat: add anthropic SDK to sidecar dependencies"
```

---

## Task 2: Pydantic models for `/brain/decide`

**Files:**
- Modify: `memory_sidecar/models.py`

- [ ] **Step 1: Write the failing test**

Add to `memory_sidecar/tests/test_memory.py`:
```python
def test_brain_decide_request_defaults():
    from models import BrainDecideRequest
    req = BrainDecideRequest(snapshot_json="{}")
    assert req.recent_speech == []
    assert req.last_spoke_seconds_ago == 9999.0
    assert req.last_spoke_text is None

def test_proactive_decision_response_speak():
    from models import ProactiveDecisionResponse
    r = ProactiveDecisionResponse(action="speak", text="Hello!", reason="test")
    assert r.action == "speak"
    assert r.text == "Hello!"

def test_proactive_decision_response_silent_text_is_none():
    from models import ProactiveDecisionResponse
    r = ProactiveDecisionResponse(action="silent", reason="focused")
    assert r.text is None

def test_proactive_decision_response_rejects_invalid_action():
    from models import ProactiveDecisionResponse
    import pytest
    with pytest.raises(Exception):
        ProactiveDecisionResponse(action="shout", reason="bad")
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_brain_decide_request_defaults -v
```
Expected: `FAILED` — `ImportError: cannot import name 'BrainDecideRequest'`

- [ ] **Step 3: Implement the models**

In `memory_sidecar/models.py`, change line 3 from:
```python
from typing import Optional
```
to:
```python
from typing import Optional, Literal
```

Then append after `ReflectResponse`:
```python
class BrainDecideRequest(BaseModel):
    snapshot_json: str
    recent_speech: list[str] = []
    last_spoke_seconds_ago: float = 9999.0
    last_spoke_text: Optional[str] = None

class ProactiveDecisionResponse(BaseModel):
    action: Literal["speak", "silent"]
    text: Optional[str] = None
    reason: str
```

- [ ] **Step 4: Run all four tests to verify they pass**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_brain_decide_request_defaults tests/test_memory.py::test_proactive_decision_response_speak tests/test_memory.py::test_proactive_decision_response_silent_text_is_none tests/test_memory.py::test_proactive_decision_response_rejects_invalid_action -v
```
Expected: `4 passed`

- [ ] **Step 5: Run full test suite**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/ -v
```
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add memory_sidecar/models.py memory_sidecar/tests/test_memory.py
git commit -m "feat: add BrainDecideRequest and ProactiveDecisionResponse Pydantic models"
```

---

## Task 3: `brain_decide()` in memory.py

**Files:**
- Modify: `memory_sidecar/memory.py`
- Modify: `memory_sidecar/tests/test_memory.py`

- [ ] **Step 1: Write the failing tests**

Add to `memory_sidecar/tests/test_memory.py`:
```python
import os

@pytest.mark.asyncio
async def test_brain_decide_returns_silent_when_no_api_key():
    with patch.dict(os.environ, {}, clear=True):
        from memory import brain_decide
        from models import BrainDecideRequest
        req = BrainDecideRequest(snapshot_json="{}", recent_speech=[])
        result = await brain_decide(req)
        assert result.action == "silent"
        assert result.text is None

@pytest.mark.asyncio
async def test_brain_decide_returns_speak_when_llm_says_speak():
    from unittest.mock import AsyncMock, MagicMock, patch
    mock_response = MagicMock()
    mock_response.content = [MagicMock(text='{"action": "speak", "text": "You seem busy!", "reason": "test"}')]
    with patch("memory.GRAPHITI", None), patch("memory.MEM0", None):
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
            with patch("anthropic.AsyncAnthropic") as mock_cls:
                mock_client = MagicMock()
                mock_client.messages.create = AsyncMock(return_value=mock_response)
                mock_cls.return_value = mock_client
                from memory import brain_decide
                from models import BrainDecideRequest
                req = BrainDecideRequest(snapshot_json="{}", recent_speech=["hello"])
                result = await brain_decide(req)
                assert result.action == "speak"
                assert result.text == "You seem busy!"

@pytest.mark.asyncio
async def test_brain_decide_returns_silent_on_llm_error():
    from unittest.mock import AsyncMock, patch
    with patch("memory.GRAPHITI", None), patch("memory.MEM0", None):
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
            with patch("anthropic.AsyncAnthropic") as mock_cls:
                mock_client = MagicMock()
                mock_client.messages.create = AsyncMock(side_effect=Exception("network error"))
                mock_cls.return_value = mock_client
                from memory import brain_decide
                from models import BrainDecideRequest
                req = BrainDecideRequest(snapshot_json="{}")
                result = await brain_decide(req)
                assert result.action == "silent"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_brain_decide_returns_silent_when_no_api_key -v
```
Expected: `FAILED` — `ImportError: cannot import name 'brain_decide'`

- [ ] **Step 3: Implement brain_decide()**

Add `import re` to the top of `memory_sidecar/memory.py` (after existing imports).

Then append to `memory_sidecar/memory.py`:
```python
BRAIN_SYSTEM_PROMPT = """You are banti, an ambient personal AI assistant running on the user's Mac.
You passively observe via camera, microphone, and screen. You have persistent
memory of people, events, and patterns.

Your job right now: decide whether to speak or stay silent.

Speak when you have something genuinely useful, curious, or warm to say.
Think like a thoughtful friend who notices things — not a notification.
Ask questions when you're curious, like a human would.
Offer help when you notice the user might need it.
Comment on something interesting you observed.

Stay silent when:
- The user is clearly focused and shouldn't be interrupted
- You spoke recently and nothing significant has changed
- You have nothing meaningful to add

Return ONLY valid JSON with no markdown fences:
{"action": "speak"|"silent", "text": "<what to say, 1-2 sentences max, or null if silent>", "reason": "<brief internal note>"}"""


async def brain_decide(req) -> "ProactiveDecisionResponse":
    """Decide whether banti should speak. Returns ProactiveDecisionResponse."""
    from models import ProactiveDecisionResponse

    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    if not anthropic_key:
        return ProactiveDecisionResponse(action="silent", reason="ANTHROPIC_API_KEY missing")

    # --- assemble context ---
    import json
    context_parts = []

    # snapshot signals
    try:
        snap = json.loads(req.snapshot_json)
        if snap:
            context_parts.append(f"Current perception: {json.dumps(snap, indent=None)}")
    except Exception:
        pass

    # recent speech
    if req.recent_speech:
        lines = "\n".join(f"  - {s}" for s in req.recent_speech)
        context_parts.append(f"Recent speech:\n{lines}")

    # temporal memory (Graphiti)
    if GRAPHITI is not None:
        try:
            query_hint = "recent events and who is present"
            edges = await GRAPHITI.search(query_hint, num_results=3)
            facts = [e.fact for e in edges if e.fact]
            if facts:
                context_parts.append("Temporal memory:\n" + "\n".join(f"  - {f}" for f in facts))
        except Exception as e:
            print(f"[warn] brain_decide: Graphiti search failed: {e}")

    # semantic memory (mem0) for named person
    if MEM0 is not None:
        try:
            snap_dict = json.loads(req.snapshot_json) if req.snapshot_json != "{}" else {}
            person = snap_dict.get("person")
            if person and person.get("name") and person.get("id"):
                user_id = f"person_{person['id']}"
                hits = MEM0.search(person["name"], user_id=user_id, limit=3)
                facts = [h["memory"] for h in hits if "memory" in h]
                if facts:
                    context_parts.append(f"What I know about {person['name']}:\n" +
                                         "\n".join(f"  - {f}" for f in facts))
        except Exception as e:
            print(f"[warn] brain_decide: mem0 search failed: {e}")

    # self model
    self_json_path = os.path.expanduser("~/Library/Application Support/banti/self.json")
    if os.path.exists(self_json_path):
        try:
            with open(self_json_path) as f:
                self_data = json.load(f)
            if self_data.get("recent_patterns"):
                patterns = self_data["recent_patterns"][:3]
                context_parts.append("My recent patterns:\n" + "\n".join(f"  - {p}" for p in patterns))
        except Exception:
            pass

    # last spoke context
    if req.last_spoke_seconds_ago < 9999:
        context_parts.append(
            f"I last spoke {req.last_spoke_seconds_ago:.0f}s ago"
            + (f': "{req.last_spoke_text}"' if req.last_spoke_text else "")
        )

    user_content = "\n\n".join(context_parts) if context_parts else "No context available yet."

    try:
        import anthropic
        client = anthropic.AsyncAnthropic(api_key=anthropic_key)
        response = await client.messages.create(
            model="claude-opus-4-6",
            max_tokens=150,
            system=BRAIN_SYSTEM_PROMPT,
            messages=[{"role": "user", "content": user_content}],
        )
        raw = response.content[0].text
        raw = re.sub(r'^```[a-z]*\n?|\n?```$', '', raw.strip())
        data = json.loads(raw)
        return ProactiveDecisionResponse(
            action=data.get("action", "silent"),
            text=data.get("text") or None,
            reason=data.get("reason", ""),
        )
    except Exception as e:
        print(f"[warn] brain_decide: Opus call failed: {e}")
        return ProactiveDecisionResponse(action="silent", reason=f"llm error: {e}")
```

- [ ] **Step 4: Run the brain_decide tests**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_brain_decide_returns_silent_when_no_api_key tests/test_memory.py::test_brain_decide_returns_speak_when_llm_says_speak tests/test_memory.py::test_brain_decide_returns_silent_on_llm_error -v
```
Expected: `3 passed`

- [ ] **Step 5: Run full test suite**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/ -v
```
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add memory_sidecar/memory.py memory_sidecar/tests/test_memory.py
git commit -m "feat: add brain_decide() — Opus 4.6 proactive speak/silent decision"
```

---

## Task 4: `/brain/decide` FastAPI endpoint

**Files:**
- Modify: `memory_sidecar/main.py`
- Modify: `memory_sidecar/tests/test_memory.py`

- [ ] **Step 1: Write the failing test**

Add to `memory_sidecar/tests/test_memory.py`:
```python
@pytest.mark.asyncio
async def test_brain_decide_endpoint_returns_silent_when_no_key():
    from unittest.mock import patch
    import os
    env = {k: v for k, v in os.environ.items() if k != "ANTHROPIC_API_KEY"}
    with patch.dict(os.environ, env, clear=True):
        from main import create_app
        app = create_app(testing=True)
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/brain/decide", json={
                "snapshot_json": "{}",
                "recent_speech": []
            })
    assert response.status_code == 200
    data = response.json()
    assert data["action"] == "silent"
    assert data["text"] is None
    assert "reason" in data
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_brain_decide_endpoint_returns_silent_when_no_key -v
```
Expected: `FAILED` — `404 Not Found` (route doesn't exist yet)

- [ ] **Step 3: Add the route to main.py**

In `memory_sidecar/main.py`, before `return app`, add:
```python
    from models import BrainDecideRequest, ProactiveDecisionResponse

    @app.post("/brain/decide", response_model=ProactiveDecisionResponse)
    async def brain_decide_endpoint(req: BrainDecideRequest):
        from memory import brain_decide
        return await brain_decide(req)
```

- [ ] **Step 4: Run the test**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_brain_decide_endpoint_returns_silent_when_no_key -v
```
Expected: `1 passed`

- [ ] **Step 5: Run the full test suite to check for regressions**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/ -v
```
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add memory_sidecar/main.py memory_sidecar/tests/test_memory.py
git commit -m "feat: add POST /brain/decide endpoint"
```

---

## Task 5: Upgrade `query_memory` to Opus 4.6

**Files:**
- Modify: `memory_sidecar/memory.py`
- Modify: `memory_sidecar/tests/test_memory.py`

- [ ] **Step 1: Write the failing test**

Add to `memory_sidecar/tests/test_memory.py`:
```python
@pytest.mark.asyncio
async def test_query_memory_uses_anthropic_when_key_present():
    """Verify query_memory calls Anthropic (not OpenAI) for answer fusion."""
    from unittest.mock import AsyncMock, MagicMock, patch
    mock_response = MagicMock()
    mock_response.content = [MagicMock(text="Alice is a software engineer.")]
    with patch("memory.GRAPHITI", None):
        with patch("memory.MEM0") as mock_mem0:
            mock_mem0.search.return_value = [{"memory": "Alice is a software engineer"}]
            with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
                # OpenAI should NOT be called
                with patch("openai.AsyncOpenAI") as mock_openai:
                    with patch("anthropic.AsyncAnthropic") as mock_anthropic_cls:
                        mock_client = MagicMock()
                        mock_client.messages.create = AsyncMock(return_value=mock_response)
                        mock_anthropic_cls.return_value = mock_client
                        from memory import query_memory
                        result = await query_memory("who is Alice?")
                        assert result["answer"] == "Alice is a software engineer."
                        mock_openai.assert_not_called()
                        mock_anthropic_cls.assert_called_once()

@pytest.mark.asyncio
async def test_query_memory_silent_when_no_anthropic_key_and_no_openai_key():
    with patch("memory.MEM0") as mock_mem0:
        mock_mem0.search.return_value = [{"memory": "some fact"}]
        with patch("memory.GRAPHITI", None):
            env = {k: v for k, v in os.environ.items()
                   if k not in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY")}
            with patch.dict(os.environ, env, clear=True):
                from memory import query_memory
                result = await query_memory("test?")
                # returns raw sources without LLM fusion
                assert result["answer"] == "some fact"
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_query_memory_uses_anthropic_when_key_present -v
```
Expected: `FAILED` — test will fail because current code uses OpenAI

- [ ] **Step 3: Upgrade query_memory in memory.py**

Replace the LLM section in `query_memory` (the block starting with `openai_key = os.environ.get("OPENAI_API_KEY")` at line ~148) with:
```python
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    if not anthropic_key:
        return {"answer": ". ".join(results[:3]), "sources": results}

    try:
        import anthropic
        client = anthropic.AsyncAnthropic(api_key=anthropic_key)
        facts = "\n".join(f"- {r}" for r in results)
        system_content = "You are banti's memory. Answer the user's question using only the provided facts. Be concise."
        if context_json:
            system_content += f" Current context: {context_json}"
        response = await client.messages.create(
            model="claude-opus-4-6",
            max_tokens=200,
            system=system_content,
            messages=[{"role": "user", "content": f"Facts:\n{facts}\n\nQuestion: {q}"}],
        )
        answer = response.content[0].text or ""
    except Exception as e:
        print(f"[warn] Opus query fusion failed: {e}")
        answer = ". ".join(results[:3])

    return {"answer": answer, "sources": results}
```

- [ ] **Step 4: Run the upgrade tests**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_query_memory_uses_anthropic_when_key_present tests/test_memory.py::test_query_memory_silent_when_no_anthropic_key_and_no_openai_key -v
```
Expected: `2 passed`

- [ ] **Step 5: Run full test suite**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/ -v
```
Expected: all pass (no regressions)

- [ ] **Step 6: Commit**

```bash
git add memory_sidecar/memory.py memory_sidecar/tests/test_memory.py
git commit -m "feat: upgrade query_memory to Claude Opus 4.6 (was GPT-4o)"
```

---

## Task 6: Upgrade `reflect_memory` to Opus 4.6

**Files:**
- Modify: `memory_sidecar/memory.py`
- Modify: `memory_sidecar/tests/test_memory.py`

- [ ] **Step 1: Write the failing test**

Add to `memory_sidecar/tests/test_memory.py`:
```python
@pytest.mark.asyncio
async def test_reflect_memory_uses_anthropic():
    from unittest.mock import AsyncMock, MagicMock, patch
    mock_response = MagicMock()
    mock_response.content = [MagicMock(text='{"observations": [], "patterns": ["user codes a lot"], "relationships": [], "summary": "User was coding"}')]
    with patch("memory.MEM0", None):
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
            with patch("openai.AsyncOpenAI") as mock_openai:
                with patch("anthropic.AsyncAnthropic") as mock_anthropic_cls:
                    mock_client = MagicMock()
                    mock_client.messages.create = AsyncMock(return_value=mock_response)
                    mock_anthropic_cls.return_value = mock_client
                    from memory import reflect_memory
                    result = await reflect_memory([SAMPLE_SNAPSHOT])
                    assert result["summary"] == "User was coding"
                    mock_openai.assert_not_called()
                    mock_anthropic_cls.assert_called_once()

@pytest.mark.asyncio
async def test_reflect_memory_handles_fenced_json():
    """Ensure markdown-fenced JSON from Opus is handled correctly."""
    from unittest.mock import AsyncMock, MagicMock, patch
    fenced = '```json\n{"observations": [], "patterns": [], "relationships": [], "summary": "ok"}\n```'
    mock_response = MagicMock()
    mock_response.content = [MagicMock(text=fenced)]
    with patch("memory.MEM0", None):
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}):
            with patch("anthropic.AsyncAnthropic") as mock_cls:
                mock_client = MagicMock()
                mock_client.messages.create = AsyncMock(return_value=mock_response)
                mock_cls.return_value = mock_client
                from memory import reflect_memory
                result = await reflect_memory([SAMPLE_SNAPSHOT])
                assert result["summary"] == "ok"
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_reflect_memory_uses_anthropic -v
```
Expected: `FAILED`

- [ ] **Step 3: Upgrade reflect_memory in memory.py**

Keep the existing `episodes` list build-up and `context` string construction at the top of `reflect_memory` (the `for snap in snapshots:` loop and `context = "\n".join(...)` line) exactly as they are — only replace the block starting with `openai_key = os.environ.get("OPENAI_API_KEY")` with:
```python
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    if not anthropic_key:
        return {"summary": ""}

    prompt = f"""You are banti's self-model. Analyze recent observations and respond with JSON.
Return ONLY valid JSON with no markdown fences:
{{
  "observations": ["time-anchored facts"],
  "patterns": ["recurring signals"],
  "relationships": [{{"person": "Name", "facts": ["..."]}}],
  "summary": "one sentence"
}}

Recent observations:
{context}"""

    try:
        import anthropic
        client = anthropic.AsyncAnthropic(api_key=anthropic_key)
        resp = await client.messages.create(
            model="claude-opus-4-6",
            max_tokens=500,
            messages=[{"role": "user", "content": prompt}],
        )
        raw = resp.content[0].text or "{}"
        raw = re.sub(r'^```[a-z]*\n?|\n?```$', '', raw.strip())
        result = json.loads(raw)
    except Exception as e:
        print(f"[warn] Opus reflection failed: {e}")
        return {"summary": "reflection failed"}
```

Keep the rest of `reflect_memory` (self.json write + mem0 pattern storage) unchanged.

- [ ] **Step 4: Run reflect tests**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/test_memory.py::test_reflect_memory_uses_anthropic tests/test_memory.py::test_reflect_memory_handles_fenced_json -v
```
Expected: `2 passed`

- [ ] **Step 5: Run full suite**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/ -v
```
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add memory_sidecar/memory.py memory_sidecar/tests/test_memory.py
git commit -m "feat: upgrade reflect_memory to Claude Opus 4.6 (was GPT-4o)"
```

---

## Task 7: `ProactiveDecision` struct in Swift

**Files:**
- Modify: `Sources/BantiCore/MemoryTypes.swift`
- Modify: `Tests/BantiTests/MemoryTypesTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Tests/BantiTests/MemoryTypesTests.swift`, add:
```swift
func testProactiveDecisionDecodesSpeakWithText() throws {
    let json = """
    {"action":"speak","text":"Hello there!","reason":"user looks idle"}
    """.data(using: .utf8)!
    let decision = try JSONDecoder().decode(ProactiveDecision.self, from: json)
    XCTAssertEqual(decision.action, "speak")
    XCTAssertEqual(decision.text, "Hello there!")
    XCTAssertEqual(decision.reason, "user looks idle")
}

func testProactiveDecisionDecodesSilentWithNilText() throws {
    let json = """
    {"action":"silent","text":null,"reason":"focused"}
    """.data(using: .utf8)!
    let decision = try JSONDecoder().decode(ProactiveDecision.self, from: json)
    XCTAssertEqual(decision.action, "silent")
    XCTAssertNil(decision.text)
}

func testProactiveDecisionDecodesSilentWithMissingText() throws {
    let json = """
    {"action":"silent","reason":"nothing to add"}
    """.data(using: .utf8)!
    let decision = try JSONDecoder().decode(ProactiveDecision.self, from: json)
    XCTAssertNil(decision.text)
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter MemoryTypesTests 2>&1 | tail -20
```
Expected: compile error — `ProactiveDecision` not found

- [ ] **Step 3: Add ProactiveDecision to MemoryTypes.swift**

Append to `Sources/BantiCore/MemoryTypes.swift`:
```swift
// MARK: - ProactiveDecision

public struct ProactiveDecision: Decodable {
    public let action: String   // "speak" or "silent"
    public let text: String?
    public let reason: String

    public init(action: String, text: String?, reason: String) {
        self.action = action
        self.text = text
        self.reason = reason
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter MemoryTypesTests 2>&1 | tail -20
```
Expected: all `MemoryTypesTests` pass

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/MemoryTypes.swift Tests/BantiTests/MemoryTypesTests.swift
git commit -m "feat: add ProactiveDecision Decodable struct to MemoryTypes"
```

---

## Task 8: `CartesiaSpeaker` actor

**Files:**
- Create: `Sources/BantiCore/CartesiaSpeaker.swift`
- Create: `Tests/BantiTests/CartesiaSpeakerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/BantiTests/CartesiaSpeakerTests.swift`:
```swift
// Tests/BantiTests/CartesiaSpeakerTests.swift
import XCTest
import AVFoundation
@testable import BantiCore

final class CartesiaSpeakerTests: XCTestCase {

    func testIsAvailableFalseWhenNoAPIKey() async {
        let speaker = CartesiaSpeaker(logger: Logger(), apiKey: nil, voiceID: "test-voice")
        let available = await speaker.isAvailable
        XCTAssertFalse(available)
    }

    func testIsAvailableTrueWhenAPIKeyPresent() async {
        let speaker = CartesiaSpeaker(logger: Logger(), apiKey: "test-key", voiceID: "test-voice")
        let available = await speaker.isAvailable
        XCTAssertTrue(available)
    }

    func testSpeakDoesNotCrashWhenUnavailable() async {
        let speaker = CartesiaSpeaker(logger: Logger(), apiKey: nil, voiceID: "test-voice")
        // Should be a no-op — just verify no crash
        await speaker.speak("hello")
    }

    func testMakeBufferReturnsNilForEmptyData() {
        let result = CartesiaSpeaker.makeBuffer(Data(), sampleRate: 22050)
        XCTAssertNil(result)
    }

    func testMakeBufferReturnsPCMBufferForValidData() {
        // 100 frames of Int16 mono PCM = 200 bytes
        let bytes = Data(repeating: 0, count: 200)
        let buffer = CartesiaSpeaker.makeBuffer(bytes, sampleRate: 22050)
        XCTAssertNotNil(buffer)
        XCTAssertEqual(buffer?.frameLength, 100)
    }

    func testPendingTextIsReplacedWhenSpeakCalledWhileBusy() async {
        let speaker = CartesiaSpeaker(logger: Logger(), apiKey: "key", voiceID: "voice")
        // Simulate busy state and queue replacement
        await speaker.setIsSpeakingForTest(true)
        await speaker.speak("first message")
        await speaker.speak("second message")  // should replace first
        let pending = await speaker.pendingTextForTest
        XCTAssertEqual(pending, "second message")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter CartesiaSpeakerTests 2>&1 | tail -20
```
Expected: compile error — `CartesiaSpeaker` not found

- [ ] **Step 3: Implement CartesiaSpeaker**

Create `Sources/BantiCore/CartesiaSpeaker.swift`:
```swift
// Sources/BantiCore/CartesiaSpeaker.swift
import Foundation
import AVFoundation

public actor CartesiaSpeaker {
    private let apiKey: String?
    private let voiceID: String
    private let logger: Logger
    private let session: URLSession

    // Playback state
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var engineStarted = false

    // Queue: at most one pending text (replaces previous if still pending)
    var pendingText: String?         // internal — exposed for tests via accessor
    var isSpeaking: Bool = false     // internal — exposed for tests via accessor

    public var isAvailable: Bool { apiKey != nil }

    public init(logger: Logger,
                apiKey: String? = ProcessInfo.processInfo.environment["CARTESIA_API_KEY"],
                voiceID: String = ProcessInfo.processInfo.environment["CARTESIA_VOICE_ID"]
                             ?? "a0e99841-438c-4a64-b679-ae501e7d6091",
                session: URLSession = .shared) {
        self.logger = logger
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.session = session
    }

    public func speak(_ text: String) {
        guard isAvailable else {
            logger.log(source: "tts", message: "[info] Cartesia unavailable — would say: \(text)")
            return
        }
        if isSpeaking {
            pendingText = text
            return
        }
        isSpeaking = true
        Task { await playSpeech(text) }
    }

    private func playSpeech(_ text: String) async {
        defer {
            isSpeaking = false
            if let next = pendingText {
                pendingText = nil
                speak(next)
            }
        }

        guard let key = apiKey,
              let url = URL(string: "https://api.cartesia.ai/tts/bytes") else { return }

        let body: [String: Any] = [
            "model_id": "sonic-2",
            "transcript": text,
            "voice": ["mode": "id", "id": voiceID],
            "output_format": ["container": "raw", "encoding": "pcm_s16le", "sample_rate": 22050]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.setValue("2024-06-10", forHTTPHeaderField: "Cartesia-Version")

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                logger.log(source: "tts", message: "[warn] Cartesia HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            guard let buffer = CartesiaSpeaker.makeBuffer(data) else {
                logger.log(source: "tts", message: "[warn] CartesiaSpeaker: failed to build PCM buffer")
                return
            }
            playBuffer(buffer)
        } catch {
            logger.log(source: "tts", message: "[warn] CartesiaSpeaker: \(error.localizedDescription)")
        }
    }

    private func playBuffer(_ buffer: AVAudioPCMBuffer) {
        if !engineStarted {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: buffer.format)
            try? engine.start()
            engineStarted = true
        }
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in }
        if !playerNode.isPlaying { playerNode.play() }
    }

    /// Construct an AVAudioPCMBuffer from raw pcm_s16le mono bytes at 22050 Hz.
    public static func makeBuffer(_ data: Data, sampleRate: Double = 22050) -> AVAudioPCMBuffer? {
        guard !data.isEmpty else { return nil }
        let frameCount = AVAudioFrameCount(data.count / 2)  // Int16 = 2 bytes per frame
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { ptr in
            guard let src = ptr.bindMemory(to: Int16.self).baseAddress,
                  let dst = buffer.int16ChannelData?[0] else { return }
            dst.update(from: src, count: Int(frameCount))
        }
        return buffer
    }

    // MARK: - Test helpers (internal access for tests in same module)
    func setIsSpeakingForTest(_ value: Bool) { isSpeaking = value }
    var pendingTextForTest: String? { pendingText }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter CartesiaSpeakerTests 2>&1 | tail -30
```
Expected: all `CartesiaSpeakerTests` pass

- [ ] **Step 5: Run full Swift test suite**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test 2>&1 | tail -20
```
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/BantiCore/CartesiaSpeaker.swift Tests/BantiTests/CartesiaSpeakerTests.swift
git commit -m "feat: CartesiaSpeaker — Cartesia REST API → PCM → AVAudioEngine"
```

---

## Task 9: `BrainLoop` actor

**Files:**
- Create: `Sources/BantiCore/BrainLoop.swift`
- Create: `Tests/BantiTests/BrainLoopTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/BantiTests/BrainLoopTests.swift`:
```swift
// Tests/BantiTests/BrainLoopTests.swift
import XCTest
@testable import BantiCore

final class BrainLoopTests: XCTestCase {

    // MARK: - Cooldown

    func testShouldTriggerTrueWhenNeverSpoke() {
        XCTAssertTrue(BrainLoop.shouldTrigger(lastSpoke: nil))
    }

    func testShouldTriggerFalseWithin10Seconds() {
        let recentlySpoke = Date().addingTimeInterval(-5)
        XCTAssertFalse(BrainLoop.shouldTrigger(lastSpoke: recentlySpoke))
    }

    func testShouldTriggerTrueAfter10Seconds() {
        let longAgo = Date().addingTimeInterval(-11)
        XCTAssertTrue(BrainLoop.shouldTrigger(lastSpoke: longAgo))
    }

    func testShouldTriggerFalseExactlyAt10Seconds() {
        // At exactly 10s it should NOT trigger yet (strictly greater than)
        let exactly10 = Date().addingTimeInterval(-10)
        XCTAssertFalse(BrainLoop.shouldTrigger(lastSpoke: exactly10))
    }

    // MARK: - Transcript buffer

    func testAppendTranscriptIgnoresNonFinal() {
        var transcripts: [String] = []
        BrainLoop.appendTranscript(&transcripts, new: "hello", isFinal: false)
        XCTAssertTrue(transcripts.isEmpty)
    }

    func testAppendTranscriptAddsFinalTranscript() {
        var transcripts: [String] = []
        BrainLoop.appendTranscript(&transcripts, new: "hello", isFinal: true)
        XCTAssertEqual(transcripts, ["hello"])
    }

    func testAppendTranscriptIgnoresDuplicate() {
        var transcripts = ["hello"]
        BrainLoop.appendTranscript(&transcripts, new: "hello", isFinal: true)
        XCTAssertEqual(transcripts.count, 1)
    }

    func testAppendTranscriptIgnoresNil() {
        var transcripts: [String] = []
        BrainLoop.appendTranscript(&transcripts, new: nil, isFinal: true)
        XCTAssertTrue(transcripts.isEmpty)
    }

    func testTranscriptBufferCapsAt5() {
        var transcripts: [String] = []
        for i in 1...7 {
            BrainLoop.appendTranscript(&transcripts, new: "line \(i)", isFinal: true)
        }
        XCTAssertEqual(transcripts.count, 5)
        XCTAssertEqual(transcripts.first, "line 3")
        XCTAssertEqual(transcripts.last, "line 7")
    }

    // MARK: - ProactiveDecision parsing

    func testDecodesSpeakDecision() throws {
        let json = #"{"action":"speak","text":"Hello!","reason":"idle"}"#.data(using: .utf8)!
        let decision = try JSONDecoder().decode(ProactiveDecision.self, from: json)
        XCTAssertEqual(decision.action, "speak")
        XCTAssertEqual(decision.text, "Hello!")
    }

    func testDecodesSilentDecision() throws {
        let json = #"{"action":"silent","text":null,"reason":"busy"}"#.data(using: .utf8)!
        let decision = try JSONDecoder().decode(ProactiveDecision.self, from: json)
        XCTAssertEqual(decision.action, "silent")
        XCTAssertNil(decision.text)
    }

    // MARK: - Event trigger detection

    func testIsEmotionSpikeTrueWhenValenceDropsBelow0Point3() {
        // Simulate a strong negative emotion state (valence as a proxy: sadness/fear score > 0.7)
        XCTAssertTrue(BrainLoop.isEmotionSpike(topScore: 0.8))
    }

    func testIsEmotionSpikeFalseForMildEmotion() {
        XCTAssertFalse(BrainLoop.isEmotionSpike(topScore: 0.4))
    }

    func testUnknownPersonExceedsThresholdAfter30Seconds() {
        let firstSeen = Date().addingTimeInterval(-31)
        XCTAssertTrue(BrainLoop.unknownPersonExceedsThreshold(firstSeen: firstSeen))
    }

    func testUnknownPersonDoesNotExceedThresholdBefore30Seconds() {
        let firstSeen = Date().addingTimeInterval(-20)
        XCTAssertFalse(BrainLoop.unknownPersonExceedsThreshold(firstSeen: firstSeen))
    }

    func testNameJustResolvedDetectsTransitionFromNilToName() {
        XCTAssertTrue(BrainLoop.nameJustResolved(previous: nil, current: "Alice"))
    }

    func testNameJustResolvedFalseWhenAlreadyKnown() {
        XCTAssertFalse(BrainLoop.nameJustResolved(previous: "Alice", current: "Alice"))
    }

    func testNameJustResolvedFalseWhenStillUnknown() {
        XCTAssertFalse(BrainLoop.nameJustResolved(previous: nil, current: nil))
    }

    // MARK: - lastSpoke seconds calculation

    func testSecondsSinceLastSpokeIsLargeWhenNeverSpoke() {
        let secs = BrainLoop.secondsSince(nil)
        XCTAssertGreaterThan(secs, 9998)
    }

    func testSecondsSinceLastSpokeIsAccurate() {
        let t = Date().addingTimeInterval(-30)
        let secs = BrainLoop.secondsSince(t)
        XCTAssertGreaterThanOrEqual(secs, 29)
        XCTAssertLessThan(secs, 32)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter BrainLoopTests 2>&1 | tail -20
```
Expected: compile error — `BrainLoop` not found

- [ ] **Step 3: Implement BrainLoop**

Create `Sources/BantiCore/BrainLoop.swift`:
```swift
// Sources/BantiCore/BrainLoop.swift
import Foundation

public actor BrainLoop {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let speaker: CartesiaSpeaker
    private let logger: Logger

    private static let heartbeatNanoseconds: UInt64 = 15_000_000_000  // 15s
    private static let pollNanoseconds: UInt64 = 2_000_000_000        // 2s
    private static let cooldownSeconds: Double = 10.0
    private static let maxTranscripts = 5

    private var lastSpoke: Date?
    private var lastSpokeText: String?
    private var recentTranscripts: [String] = []
    private var lastPersonID: String?
    private var lastPersonName: String?
    private var unknownPersonFirstSeen: Date?

    public init(context: PerceptionContext, sidecar: MemorySidecar,
                speaker: CartesiaSpeaker, logger: Logger) {
        self.context = context
        self.sidecar = sidecar
        self.speaker = speaker
        self.logger = logger
    }

    // start() is non-async — spawns internal Tasks
    public func start() {
        // Heartbeat loop
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BrainLoop.heartbeatNanoseconds)
                await self.evaluate(reason: "heartbeat")
            }
        }
        // Event polling loop (2s)
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BrainLoop.pollNanoseconds)
                await self.pollEvents()
            }
        }
    }

    private func pollEvents() async {
        // 1. Accumulate final transcripts
        let currentSpeech = await context.speech
        BrainLoop.appendTranscript(&recentTranscripts,
                                   new: currentSpeech?.transcript,
                                   isFinal: currentSpeech?.isFinal ?? false)

        let person = await context.person

        // 2. Trigger on new person (ID changed)
        if let person {
            if person.id != lastPersonID {
                lastPersonID = person.id
                unknownPersonFirstSeen = person.name == nil ? Date() : nil
                await evaluate(reason: "new person detected")
            }

            // 3. Trigger when name just resolved (unknown → named)
            if BrainLoop.nameJustResolved(previous: lastPersonName, current: person.name) {
                lastPersonName = person.name
                await evaluate(reason: "person name resolved: \(person.name ?? "")")
            } else {
                lastPersonName = person.name
            }

            // 4. Trigger when unknown person present > 30s
            if person.name == nil,
               let firstSeen = unknownPersonFirstSeen,
               BrainLoop.unknownPersonExceedsThreshold(firstSeen: firstSeen) {
                unknownPersonFirstSeen = nil  // reset so we don't re-trigger immediately
                await evaluate(reason: "unknown person present > 30s")
            }
        } else {
            lastPersonID = nil
            lastPersonName = nil
            unknownPersonFirstSeen = nil
        }

        // 5. Trigger on voice emotion spike (Hume VoiceEmotionState)
        if let ve = await context.voiceEmotion {
            let topScore = ve.emotions.map { $0.score }.max() ?? 0
            if BrainLoop.isEmotionSpike(topScore: topScore) {
                await evaluate(reason: "emotion spike detected")
            }
        }
    }

    private func evaluate(reason: String) async {
        guard BrainLoop.shouldTrigger(lastSpoke: lastSpoke) else { return }
        guard await sidecar.isRunning else { return }

        let snapshot = await context.snapshotJSON()
        let secondsAgo = BrainLoop.secondsSince(lastSpoke)

        struct BrainBody: Encodable {
            let snapshot_json: String
            let recent_speech: [String]
            let last_spoke_seconds_ago: Double
            let last_spoke_text: String?
        }
        let body = BrainBody(
            snapshot_json: snapshot,
            recent_speech: recentTranscripts,
            last_spoke_seconds_ago: secondsAgo,
            last_spoke_text: lastSpokeText
        )

        guard let url = URL(string: "/brain/decide", relativeTo: sidecar.baseURL),
              let bodyData = try? JSONEncoder().encode(body) else { return }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decision = try JSONDecoder().decode(ProactiveDecision.self, from: data)
            logger.log(source: "brain", message: "[\(reason)] \(decision.action): \(decision.reason)")
            if decision.action == "speak", let text = decision.text, !text.isEmpty {
                lastSpoke = Date()
                lastSpokeText = text
                await speaker.speak(text)
            }
        } catch {
            logger.log(source: "brain", message: "[warn] brain/decide failed: \(error.localizedDescription)")
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

    public static func secondsSince(_ date: Date?) -> Double {
        guard let date else { return 9999.0 }
        return Date().timeIntervalSince(date)
    }

    /// Returns true when Hume voice emotion top score exceeds 0.7 (strong signal).
    public static func isEmotionSpike(topScore: Float) -> Bool {
        return topScore >= 0.7
    }

    /// Returns true when an unnamed person has been visible for > 30 seconds.
    public static func unknownPersonExceedsThreshold(firstSeen: Date, now: Date = Date()) -> Bool {
        return now.timeIntervalSince(firstSeen) > 30.0
    }

    /// Returns true when name transitions from nil to a non-nil value (just resolved).
    public static func nameJustResolved(previous: String?, current: String?) -> Bool {
        return previous == nil && current != nil
    }
}
```

- [ ] **Step 4: Run BrainLoop tests**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter BrainLoopTests 2>&1 | tail -30
```
Expected: all `BrainLoopTests` pass

- [ ] **Step 5: Run full Swift test suite**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test 2>&1 | tail -20
```
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/BantiCore/BrainLoop.swift Tests/BantiTests/BrainLoopTests.swift
git commit -m "feat: BrainLoop — 15s heartbeat + event triggers + Opus 4.6 speak/silent decisions"
```

---

## Task 10: Wire `MemoryEngine` + update `.env.example`

**Files:**
- Modify: `Sources/BantiCore/MemoryEngine.swift`
- Modify: `.env.example`

- [ ] **Step 1: Write the failing test**

In `Tests/BantiTests/MemoryIngestorTests.swift` (or a new file if preferred), add:
```swift
// Add to Tests/BantiTests/MemoryIngestorTests.swift
// @testable import BantiCore already gives access to internal members
func testMemoryEngineHasBrainLoopAndCartesiaSpeaker() {
    let context = PerceptionContext()
    let audio = AudioRouter()
    let logger = Logger()
    let engine = MemoryEngine(context: context, audioRouter: audio, logger: logger)
    // brainLoop is public; cartesiaSpeaker is internal, accessible via @testable import
    _ = engine.brainLoop
    _ = engine.cartesiaSpeaker
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter testMemoryEngineHasBrainLoopAndCartesiaSpeaker 2>&1 | tail -10
```
Expected: compile error — `brainLoop` not found on `MemoryEngine`

- [ ] **Step 3: Update MemoryEngine.swift**

Replace `Sources/BantiCore/MemoryEngine.swift` content:
```swift
// Sources/BantiCore/MemoryEngine.swift
import Foundation

/// Top-level actor that owns all memory subsystems.
public actor MemoryEngine {
    private let context: PerceptionContext
    private let audioRouter: AudioRouter
    private let logger: Logger

    public let sidecar: MemorySidecar
    public let faceIdentifier: FaceIdentifier
    public let speakerResolver: SpeakerResolver
    private let memoryIngestor: MemoryIngestor
    private let selfModel: SelfModel
    public let brainLoop: BrainLoop
    let cartesiaSpeaker: CartesiaSpeaker   // internal — accessible via @testable import
    public let memoryQuery: MemoryQuery

    public init(context: PerceptionContext, audioRouter: AudioRouter, logger: Logger) {
        let sessionID = UUID().uuidString
        let port = Int(ProcessInfo.processInfo.environment["MEMORY_SIDECAR_PORT"] ?? "") ?? 7700

        self.context = context
        self.audioRouter = audioRouter
        self.logger = logger

        self.sidecar = MemorySidecar(logger: logger, port: port)

        self.faceIdentifier = FaceIdentifier(
            context: context,
            sidecar: sidecar,
            logger: logger,
            sessionID: sessionID
        )

        self.speakerResolver = SpeakerResolver(
            context: context,
            audioRouter: audioRouter,
            sidecar: sidecar,
            logger: logger,
            sessionID: sessionID
        )

        self.memoryIngestor = MemoryIngestor(context: context, sidecar: sidecar, logger: logger)
        self.selfModel = SelfModel(context: context, sidecar: sidecar, logger: logger)
        self.cartesiaSpeaker = CartesiaSpeaker(logger: logger)
        self.brainLoop = BrainLoop(context: context, sidecar: sidecar,
                                   speaker: cartesiaSpeaker, logger: logger)
        self.memoryQuery = MemoryQuery(sidecar: sidecar, logger: logger)
    }

    public func start() async {
        await sidecar.start()
        await memoryIngestor.start()
        await selfModel.start()
        await speakerResolver.start()
        brainLoop.start()    // non-async — internally spawns Tasks
        logger.log(source: "memory", message: "MemoryEngine started")
    }
}
```

Note: `proactiveIntroducer` and `startPersonObserver()` are removed. `brainLoop.start()` replaces `startPersonObserver()`.

- [ ] **Step 4: Update .env.example**

Add to `.env.example`:
```
# Anthropic (Opus 4.6 — brain loop, memory query, reflection)
ANTHROPIC_API_KEY=your_anthropic_api_key_here

# Cartesia TTS
CARTESIA_API_KEY=your_cartesia_api_key_here
CARTESIA_VOICE_ID=a0e99841-438c-4a64-b679-ae501e7d6091
```

- [ ] **Step 5: Run all Swift tests**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test 2>&1 | tail -30
```
Expected: all tests pass, no compile errors

- [ ] **Step 6: Run full Python test suite**

```bash
cd memory_sidecar && .venv/bin/python -m pytest tests/ -v
```
Expected: all tests pass

- [ ] **Step 7: Commit**

```bash
git add Sources/BantiCore/MemoryEngine.swift .env.example
git commit -m "feat: wire MemoryEngine — BrainLoop + CartesiaSpeaker, retire ProactiveIntroducer"
```

---

## Done

After Task 10:
- Banti speaks proactively using Cartesia Sonic-2 TTS
- All reasoning (brain decisions, memory query fusion, self-reflection) runs on Claude Opus 4.6
- GPT-4o remains for fast perception analysis (activity, gesture, screen)
- Full test coverage on all new components
