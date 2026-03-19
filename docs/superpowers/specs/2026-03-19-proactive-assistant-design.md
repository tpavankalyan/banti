# Proactive Assistant — Cartesia TTS + Opus 4.6 Brain

**Date:** 2026-03-19
**Status:** Approved

---

## Goal

Give banti a voice and a brain. Banti observes the environment continuously and speaks proactively — like a thoughtful friend who notices things — using Cartesia Sonic-2 for natural TTS and Claude Opus 4.6 for all deep reasoning. The LLM decides when to speak and what to say. Banti never speaks on a rigid schedule; it speaks when it has something worth saying.

---

## Requirements

| Capability | Priority |
|---|---|
| Proactive speech — banti initiates conversation without being asked | Must have |
| LLM-driven speak/silent decision (Opus 4.6) | Must have |
| Cartesia Sonic-2 TTS for natural voice output | Must have |
| Heartbeat trigger (15s) + event triggers (new person, emotion spike, name resolved) | Must have |
| Hard cooldown: minimum 10s between speeches | Must have |
| Brain has access to memory (Graphiti + mem0 + self.json) when deciding | Must have |
| Graceful degradation if Cartesia or sidecar unavailable | Must have |
| Upgrade memory query fusion to Opus 4.6 (was GPT-4o) | Must have |
| Upgrade self-model reflection to Opus 4.6 (was GPT-4o) | Must have |
| Retire ProactiveIntroducer — BrainLoop absorbs its role | Must have |
| Single consistent voice (configurable via CARTESIA_VOICE_ID) | Must have |

---

## Architecture

```
PerceptionContext (live ambient state)
        │
        ▼
BrainLoop (Swift actor)                     [NEW]
  ├── 15s heartbeat
  ├── event triggers: new person, emotion spike, name resolved
  ├── hard 10s cooldown enforced in Swift
  └── POST /brain/decide → sidecar

        │
        ▼
Python Sidecar: brain_decide()              [NEW]
  ├── query memory (Graphiti + mem0) for relevant context
  ├── load self.json (banti's self-model)
  ├── call claude-opus-4-6 with full assembled context
  └── return ProactiveDecision {action, text?, reason}

        │ (when action == "speak")
        ▼
CartesiaSpeaker (Swift actor)               [NEW]
  ├── POST https://api.cartesia.ai/tts/bytes
  ├── decode raw PCM bytes (pcm_s16le, 22050 Hz)
  └── play via AVAudioEngine + AVAudioPlayerNode
```

**Upgraded (not new):**
- `query_memory` fusion: GPT-4o → Opus 4.6
- `reflect_memory` self-model: GPT-4o → Opus 4.6
- GPT-4o **stays** for `GPT4oActivityAnalyzer`, `GPT4oGestureAnalyzer`, `GPT4oScreenAnalyzer` — 80–100 token tasks where speed matters, not depth

---

## Component Design

### BrainLoop (Swift actor)

**Owned by:** `MemoryEngine`

**Two trigger paths:**

1. **Heartbeat** — fires unconditionally every 15 seconds
2. **Event triggers** — polls `PerceptionContext` every 2 seconds for:
   - New person detected (face just appeared)
   - Emotion valence spike (Hume score crosses threshold)
   - Unknown person present > 30s (replaces `ProactiveIntroducer`)
   - Person name just resolved (unknown → named)

**Cooldown enforcement:**
- Hard minimum 10s between any `speak` action, enforced before calling sidecar
- `last_spoke_seconds_ago` is sent to sidecar so Opus can apply soft judgment too

**Recent transcript buffer:**
`BrainLoop` maintains `var recentTranscripts: [String]` (max 5 entries). On each 2-second poll, if `PerceptionContext.speech?.isFinal == true` and the transcript differs from the last entry, it is appended (oldest dropped when full). This buffer is sent as `recent_speech` in the request. If no transcripts have accumulated, an empty array is sent.

**Request payload to `/brain/decide`:**
```json
{
  "snapshot_json": "{ ...PerceptionContext.snapshotJSON() ... }",
  "recent_speech": ["last 5 final transcript strings, oldest first"],
  "last_spoke_seconds_ago": 45.2,
  "last_spoke_text": "You seem deep in thought"
}
```

**Response `ProactiveDecision`:**
```json
{ "action": "speak", "text": "Want me to look something up?", "reason": "user staring at blank screen 3 min" }
{ "action": "silent", "text": null, "reason": "user focused, spoke 8s ago" }
```

`text` is always present in the response but is `null` when `action == "silent"`.

Swift `ProactiveDecision`: `var text: String?` (optional). Python `ProactiveDecisionResponse`: `text: Optional[str] = None`.

**On `speak`:** calls `CartesiaSpeaker.speak(text)` where `text` is non-nil.

**On sidecar unavailable:** logs decision locally, stays silent.

**Timeout:** BrainLoop uses a 10-second timeout for the `/brain/decide` HTTP call (not the default 5s `MemorySidecar.post()` timeout). Call `URLSession` directly with a custom `timeoutInterval: 10` rather than going through `MemorySidecar.post()`.

---

### `/brain/decide` endpoint + `brain_decide()` (Python sidecar)

**New endpoint:** `POST /brain/decide`

**Pydantic models** (add to `models.py`):

First, update the typing import in `models.py` from `from typing import Optional` to `from typing import Optional, Literal`.

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

**Function:** `async def brain_decide(req: BrainDecideRequest) -> ProactiveDecisionResponse` in `memory.py`

**Assembly steps:**
1. Parse snapshot, extract key signals (who's present, activity, emotion, screen)
2. Run `GRAPHITI.search()` with a context-derived query (top 3 temporal facts)
3. Run `MEM0.search()` for person-specific facts if a named person is present (top 3)
4. Load `self.json` if it exists
5. Compose full context string
6. Call `claude-opus-4-6` via Anthropic SDK, max 150 tokens, JSON mode

**System prompt (banti's personality):**
```
You are banti, an ambient personal AI assistant running on the user's Mac.
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
{"action": "speak"|"silent", "text": "<what to say, 1-2 sentences max, or null if silent>", "reason": "<brief internal note>"}
```

**JSON parsing:** After receiving Opus's response, strip any markdown code fences (` ```json ... ``` ` or ` ``` ... ``` `) before calling `json.loads()`. Use: `content = re.sub(r'^```[a-z]*\n?|\n?```$', '', content.strip())`

**Graceful degradation:**
- If Graphiti unavailable: skip temporal context
- If mem0 unavailable: skip semantic context
- If Anthropic API fails: return `{"action": "silent", "reason": "llm unavailable"}`
- If `ANTHROPIC_API_KEY` missing: return silent

---

### CartesiaSpeaker (Swift actor)

**API:** `POST https://api.cartesia.ai/tts/bytes`

**Request:**
```json
{
  "model_id": "sonic-2",
  "transcript": "...",
  "voice": { "mode": "id", "id": "<CARTESIA_VOICE_ID>" },
  "output_format": { "container": "raw", "encoding": "pcm_s16le", "sample_rate": 22050 }
}
```

**Headers:** `X-API-Key: <CARTESIA_API_KEY>`, `Cartesia-Version: 2024-06-10` (verify this is current before implementation), `Content-Type: application/json`

**PCM format:** Cartesia returns mono PCM. Construct playback format as:
`AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22050, channels: 1, interleaved: true)`
Copy response bytes into `int16ChannelData[0]` of an `AVAudioPCMBuffer` sized to `byteCount / 2` frames.

**Playback:** raw PCM bytes → `AVAudioPCMBuffer` → `AVAudioPlayerNode.scheduleBuffer()` → `AVAudioEngine`

**Queue behavior:**
- One utterance plays at a time via `AVAudioPlayerNode`
- `CartesiaSpeaker` holds at most one pending `String`. If `speak()` is called while audio is playing, store the new text as the pending item, replacing any previously pending (not yet scheduled) text. Do not interrupt in-progress playback.
- Implemented as a Swift actor with `var pendingText: String?` and a serial `Task` for TTS fetching + playback

**Graceful degradation:**
- If `CARTESIA_API_KEY` missing or request fails: log text via `Logger`, stay silent

---

## Upgraded: Opus 4.6 in Memory Sidecar

**Both upgraded functions:** Add `import re` to the top of `memory.py` (needed for markdown fence stripping).

### `query_memory` (line ~120 in memory.py)
Replace `model="gpt-4o"` → `model="claude-opus-4-6"` via Anthropic SDK.
- Switch from `AsyncOpenAI` client to `AsyncAnthropic` client for this call
- Replace the `OPENAI_API_KEY` guard (`if not openai_key: return ...`) with an `ANTHROPIC_API_KEY` guard
- Anthropic SDK call structure:
  - `system` param = the existing system message string (including appended `context_json` if provided: `system_content += f" Current context: {context_json}"`)
  - `messages` = `[{"role": "user", "content": f"Facts:\n{facts}\n\nQuestion: {q}"}]`
- Max tokens stays 200

### `reflect_memory` (line ~160 in memory.py)
Replace `model="gpt-4o"` → `model="claude-opus-4-6"` via Anthropic SDK.
- Switch client
- Replace the `OPENAI_API_KEY` guard with an `ANTHROPIC_API_KEY` guard
- Remove `response_format={"type": "json_object"}` (not supported by Anthropic)
- Instruct model in the existing prompt to return only valid JSON with no markdown fences (append: `"\n\nReturn ONLY valid JSON with no markdown fences."` to the existing prompt string)
- After receiving response, strip markdown fences before `json.loads()` (same regex as `brain_decide`)
- Max tokens stays 500

---

## File Changes

| File | Type | Description |
|---|---|---|
| `Sources/BantiCore/BrainLoop.swift` | New | Heartbeat + event trigger + cooldown + sidecar call |
| `Sources/BantiCore/CartesiaSpeaker.swift` | New | Cartesia HTTP → PCM → AVAudioEngine |
| `Sources/BantiCore/MemoryTypes.swift` | Modified | Add `ProactiveDecision` Codable struct |
| `Sources/BantiCore/MemoryEngine.swift` | Modified | Own BrainLoop + CartesiaSpeaker, retire ProactiveIntroducer |
| `memory_sidecar/memory.py` | Modified | Add `brain_decide()`, upgrade query+reflect to Opus 4.6 |
| `memory_sidecar/main.py` | Modified | Add `POST /brain/decide` endpoint |
| `memory_sidecar/models.py` | Modified | Add `BrainDecideRequest`, `ProactiveDecisionResponse` Pydantic models |
| `memory_sidecar/requirements.txt` | Modified | Add `anthropic` |
| `.env.example` | Modified | Add `ANTHROPIC_API_KEY`, `CARTESIA_API_KEY`, `CARTESIA_VOICE_ID` |

**Retired:** `Sources/BantiCore/ProactiveIntroducer.swift` (logic absorbed by BrainLoop)
`ProactiveIntroducer` tests remain but the actor is no longer started from `MemoryEngine`.
Remove `startPersonObserver()` from `MemoryEngine.start()` — BrainLoop's 2-second event polling replaces it entirely.

**`MemoryEngine` modifications:**

`MemoryEngine.init` adds two new stored properties:
```swift
public let brainLoop: BrainLoop       // replaces proactiveIntroducer
private let cartesiaSpeaker: CartesiaSpeaker
```

Constructor signatures:
```swift
// CartesiaSpeaker owns its own AVAudioEngine internally — no shared engine
CartesiaSpeaker(logger: Logger)

// BrainLoop needs context (to snapshot), sidecar (to POST /brain/decide),
// speaker (to call speak()), and logger
BrainLoop(context: PerceptionContext, sidecar: MemorySidecar,
          speaker: CartesiaSpeaker, logger: Logger)
```

`MemoryEngine.start()` calls `await brainLoop.start()` in place of `startPersonObserver()`.

---

## Environment Variables

| Variable | Used by | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Python sidecar | Opus 4.6 for brain, query, reflect |
| `CARTESIA_API_KEY` | Swift | Cartesia TTS |
| `CARTESIA_VOICE_ID` | Swift | Which Cartesia voice banti uses |
| `OPENAI_API_KEY` | Python sidecar | mem0 embeddings, GPT-4o perception analyzers (unchanged) |

---

## Error Handling

| Failure | Behavior |
|---|---|
| Sidecar not running | BrainLoop skips decision, stays silent |
| `/brain/decide` HTTP error | BrainLoop stays silent, logs warning |
| Opus 4.6 API error | `brain_decide` returns `{action: "silent"}` |
| Cartesia API error | `CartesiaSpeaker` logs text via Logger, no audio |
| `CARTESIA_API_KEY` missing | `CartesiaSpeaker` falls back to silent mode on init |
| `ANTHROPIC_API_KEY` missing | `brain_decide` returns `{action: "silent"}` |

---

## Testing

- `BrainLoopTests.swift` — cooldown enforcement, event trigger logic, `ProactiveDecision` decoding
- `CartesiaSpeakerTests.swift` — mock Cartesia HTTP, verify PCM buffer scheduling, queue behavior
- `brain_decide` tested in Python with mock Graphiti/mem0 and mock Anthropic client
- `query_memory` + `reflect_memory` Anthropic upgrade tested with mock client
- No integration tests against live Cartesia/Anthropic in CI (env vars absent = graceful silent fallback)
