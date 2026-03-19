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

**Request payload to `/brain/decide`:**
```json
{
  "snapshot_json": "{ ...PerceptionContext.snapshotJSON() ... }",
  "recent_speech": ["...last 5 transcript lines..."],
  "last_spoke_seconds_ago": 45.2,
  "last_spoke_text": "You seem deep in thought"
}
```

**Response `ProactiveDecision`:**
```json
{ "action": "speak", "text": "Want me to look something up?", "reason": "user staring at blank screen 3 min" }
{ "action": "silent", "reason": "user focused, spoke 8s ago" }
```

**On `speak`:** calls `CartesiaSpeaker.speak(text)`.

**On sidecar unavailable:** logs decision locally, stays silent.

---

### `/brain/decide` endpoint + `brain_decide()` (Python sidecar)

**New endpoint:** `POST /brain/decide`

**Function:** `brain_decide(snapshot_json, recent_speech, last_spoke_seconds_ago, last_spoke_text)` in `memory.py`

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

Return ONLY valid JSON:
{"action": "speak"|"silent", "text": "<what to say, 1-2 sentences max>", "reason": "<brief internal note>"}
```

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

**Headers:** `X-API-Key: <CARTESIA_API_KEY>`, `Cartesia-Version: 2024-06-10`, `Content-Type: application/json`

**Playback:** raw PCM bytes → `AVAudioPCMBuffer` → `AVAudioPlayerNode.scheduleBuffer()` → `AVAudioEngine`

**Queue behavior:**
- One speech at a time
- If a new `speak()` call arrives while already speaking: queue it (do not cancel mid-sentence)
- Queue depth: 1 (drop older queued item if newer arrives before playback starts)

**Graceful degradation:**
- If `CARTESIA_API_KEY` missing or request fails: log text via `Logger`, stay silent

---

## Upgraded: Opus 4.6 in Memory Sidecar

### `query_memory` (line ~120 in memory.py)
Replace `model="gpt-4o"` → `model="claude-opus-4-6"` via Anthropic SDK.
- Switch from `AsyncOpenAI` client to `AsyncAnthropic` client for this call
- System prompt and user message structure remain the same
- Max tokens stays 200

### `reflect_memory` (line ~160 in memory.py)
Replace `model="gpt-4o"` → `model="claude-opus-4-6"` via Anthropic SDK.
- Switch client
- Max tokens stays 500
- `response_format: json_object` equivalent: instruct in system prompt to return only JSON

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
| `memory_sidecar/requirements.txt` | Modified | Add `anthropic` |
| `.env.example` | Modified | Add `ANTHROPIC_API_KEY`, `CARTESIA_API_KEY`, `CARTESIA_VOICE_ID` |

**Retired:** `Sources/BantiCore/ProactiveIntroducer.swift` (logic absorbed by BrainLoop)
`ProactiveIntroducer` tests remain but the actor is no longer started from `MemoryEngine`.

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
