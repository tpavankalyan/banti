# Cognitive Pipeline Redesign — Spec
**Date:** 2026-03-22
**Status:** Approved for implementation

---

## Problem

The current cognitive pipeline has three fundamental weaknesses:

1. **Flat, stateless context.** `ContextSnapshotActor` stores only the _latest_ value per perception source. Claude sees no sense of time, duration, or change patterns — it cannot reason "the user has been stuck on this error for 60 seconds."

2. **Purely reactive, never proactive.** The pipeline only fires when the user finishes speaking. It ignores all the rich perception data (screen changes, scene changes, app switches) that could trigger a useful unprompted response.

3. **No interruption handling.** `TTSActor` fetches a full audio blob over HTTP and plays it with no way to stop mid-speech. If the user speaks during playback, banti keeps talking.

---

## Inspiration

- **Proact-VL** (Semantic Scholar `ff1b24cc`): FLAG token mechanism — at each time step, consume multi-source tokens, compute a speak/silent score, only generate text if triggered. Separates the _decision to speak_ from _what to say_.
- **GetStream/vision-agents**: Epoch-based interrupt. Every audio chunk is tagged with the epoch at which it was generated; incrementing the epoch on barge-in makes all in-flight stale audio structurally invalid.
- **Claude API**: Prompt caching (`cache_control: ephemeral`) reduces cost for repeated calls over a stable context. Streaming responses allow TTS to begin before generation completes.
- **Cartesia WebSocket TTS**: Chunk-level streaming — text in, PCM audio out in real-time, with a `continue: false` message to flush and interrupt.

---

## New Architecture

### Actors added / replaced

| Old | New | Change |
|---|---|---|
| `ContextSnapshotActor` | `PerceptionLogActor` | Rolling temporal log replaces flat snapshot |
| `AgentBridgeActor` | `CognitiveCoreActor` | Event-driven loop, streaming, tool-use FLAG, prompt caching |
| `TurnDetectorActor` | kept, unchanged | Still handles silence-based turn segmentation |
| `TTSActor` | `StreamingTTSActor` | Cartesia WebSocket + epoch-based barge-in |

Two new event types: `SpeakChunkEvent` and `InterruptEvent`.

---

## Component 1: PerceptionLogActor

**Replaces:** `ContextSnapshotActor`

### Responsibilities

Subscribes to enriched (description-level) perception events and maintains a bounded, time-ordered rolling log. Exposes a `log()` method returning a `PerceptionLog` value type.

> **Note:** `PerceptionLogActor` subscribes to `ScreenDescriptionEvent` and `SceneDescriptionEvent` — NOT the raw `ScreenChangeEvent`/`SceneChangeEvent`. This is because the raw change events carry only a JPEG and a distance; the human-readable description text lives in the downstream description events. The `changeDistance` field is already carried by both description event types.

### Log structure

```swift
struct PerceptionLog {
    let entries: [PerceptionLogEntry]   // capped at 50, oldest dropped
    let activeApp: ActiveAppEvent?
    let axFocus: AXFocusEvent?
}

struct PerceptionLogEntry {
    let timestamp: Date
    let kind: PerceptionLogKind         // .screenDescription, .sceneDescription,
                                        //  .transcript, .appSwitch, .axFocus
    let summary: String                 // one-line human-readable summary
    let changeDistance: Float?          // from description events where available
}
```

### Event → entry mapping

> **Type note:** `ScreenDescriptionEvent.changeDistance` is `Float?` (optional). `SceneDescriptionEvent.changeDistance` is `Float` (non-optional — every scene description is change-triggered). Wrap the scene value as `Float?` when storing in `PerceptionLogEntry.changeDistance`. The formatted output always shows `dist=X.XX` for scene entries since the field is never nil there.

| Event | kind | summary | changeDistance |
|---|---|---|---|
| `ScreenDescriptionEvent` | `.screenDescription` | description text | `event.changeDistance` (already `Float?`) |
| `SceneDescriptionEvent` | `.sceneDescription` | description text | `Float?(event.changeDistance)` (wrap non-optional) |
| `TranscriptSegmentEvent` (final) | `.transcript` | `"user: \(text)"` | nil |
| `ActiveAppEvent` | `.appSwitch` | `"\(appName) (\(bundleID))"` | nil |
| `AXFocusEvent` | `.axFocus` | `"\(appName) — \(elementRole) \"\(elementTitle ?? "")\"` | nil |

**AXFocus deduplication:** Before appending, check if the last `.axFocus` entry matches on all three of: `appName`, `elementRole`, and `elementTitle`. Treat `nil` title as distinct from any non-nil title and also distinct from other `nil` titles — i.e., only deduplicate when all three fields are non-nil and equal. If matched, update the existing entry's timestamp instead of appending.

### Formatted output (for LLM)

Entries split into two segments at the 30-second boundary. Age-based eviction (>90s) is applied first, then the 50-entry cap (oldest removed). This ensures the cap never silently drops recent entries when the window is full.

```
=== Perception Log — Older (>30s) ===
[ 60s ago] SCREEN  dist=0.87 | Terminal — "Build failed: 3 errors"
[ 90s ago] TRANSCRIPT       | user: "why isn't this building"
...

=== Perception Log — Recent (<30s) ===
[  2s ago] SCREEN  dist=0.91 | Xcode — build error on line 42 of ContentView.swift
[  8s ago] AX_FOCUS         | Xcode — AXTextArea "ContentView.swift"
[ 15s ago] SCENE   dist=0.44 | Person leaning toward screen, focused expression

=== Active Now ===
App: Xcode (com.apple.dt.Xcode)
Focus: ContentView.swift — AXTextArea
```

The **older segment** is marked `cache_control: ephemeral` in the Claude request. The **recent segment** is always sent fresh. The older segment text is byte-for-byte stable between consecutive calls until an entry ages out of the 30s boundary, so Claude's ephemeral cache (5-min TTL) will be hit on the majority of calls.

### Capacity and retention

- **Age-evict first:** on each insertion, remove all entries with `timestamp < now - 90s`
- **Cap after age-evict:** if count > 50, remove oldest entries until count == 50
- Max 50 entries, 90s window

---

## Component 2: CognitiveCoreActor

**Replaces:** `AgentBridgeActor`

### Responsibilities

1. Subscribes to enriched perception events and decides when to trigger a Claude call (event-driven, debounced)
2. Constructs the prompt with prompt caching tiers
3. Streams the Claude response using tool-use as the FLAG mechanism
4. On "speak": streams sentence-complete text chunks to `StreamingTTSActor` in real-time
5. On `TurnStartedEvent`: cancels the in-flight LLM stream task, increments epoch, publishes `InterruptEvent`

### Epoch ownership

`CognitiveCoreActor` is the single source of truth for the epoch counter.

- `epoch: Int` starts at 0
- Incremented only in `CognitiveCoreActor.handleBargein()`
- `SpeakChunkEvent` is tagged with the current epoch at send time
- `InterruptEvent` carries the new epoch value after increment
- `StreamingTTSActor` **sets** `self.epoch = event.epoch` (not increments) when receiving `InterruptEvent`

This ensures both actors always agree: the TTS actor's epoch is derived from the interrupt event, never independently advanced.

### Trigger rules

Subscribes to: `ScreenDescriptionEvent`, `SceneDescriptionEvent`, `ActiveAppEvent`, `TurnEndedEvent`

> **Note:** `CognitiveCoreActor` triggers on description events (not raw change events), so that the perception log is already populated with the description text when the Claude call is built.

> **Note:** `AXFocusEvent` is intentionally NOT a trigger source — AX focus changes too frequently (every cursor move, every keystroke) to drive LLM calls. It enriches the perception log as passive context only.

| Trigger source | Min interval | Condition |
|---|---|---|
| `TurnEndedEvent` | 0s — always fires | Unconditional |
| `ScreenDescriptionEvent` | 5s | Only if `changeDistance >= SCREEN_PROACTIVE_THRESHOLD` (default 0.3) |
| `SceneDescriptionEvent` | 10s | Only if `changeDistance >= SCENE_PROACTIVE_THRESHOLD` (default 0.3) |
| `ActiveAppEvent` | 5s | Unconditional |

Minimum intervals are tracked per trigger source independently. Events arriving within the window are coalesced — the window expires and uses the latest available log at that point.

### `AgentLLMProvider` protocol (new signature)

The existing `AgentLLMProvider` protocol is replaced with a streaming, cancellable variant:

```swift
/// A single streamed tool-use response chunk.
enum AgentStreamEvent: Sendable {
    case speakChunk(String)     // incremental text fragment from the speak tool input
    case speakDone              // speak tool call complete
    case silent                 // model chose not to call speak
    case error(Error)
}

protocol AgentLLMProvider: Sendable {
    /// Streams a response. Returns an AsyncStream that emits AgentStreamEvents.
    /// The caller cancels the Task wrapping this call to interrupt mid-stream.
    func streamResponse(
        systemPrompt: CachedPromptBlock,
        olderContext: CachedPromptBlock,
        recentContext: String,
        triggerSource: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

struct CachedPromptBlock: Sendable {
    let text: String
    let cached: Bool            // true → include cache_control: ephemeral
}
```

The real `ClaudeAgentProvider` implements this by opening a streaming POST to `/v1/messages` and parsing SSE events (see below). The stub used in tests emits a fixed sequence of `AgentStreamEvent`s.

**Cancellation contract:** `streamTask` is a `Task<Void, Never>` in `CognitiveCoreActor`. The `ClaudeAgentProvider` implementation must check `Task.isCancelled` between each SSE event (or use `withTaskCancellationHandler`) — Swift's cooperative cancellation does not automatically terminate network I/O. On cancellation, the provider stops reading from the `URLSession` data stream and returns without emitting further events. This ensures that after `streamTask.cancel()`, no stale `SpeakChunkEvent`s are published.

### Claude API call structure

```http
POST https://api.anthropic.com/v1/messages
x-api-key: <ANTHROPIC_API_KEY>
anthropic-version: 2023-06-01
anthropic-beta: prompt-caching-2024-07-31
content-type: application/json

{
  "model": "<CLAUDE_MODEL>",
  "stream": true,
  "max_tokens": 256,
  "system": [
    {
      "type": "text",
      "text": "<banti persona + task instructions + tool usage rules>",
      "cache_control": { "type": "ephemeral" }
    }
  ],
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "<older perception log segment (>30s)>",
          "cache_control": { "type": "ephemeral" }
        },
        {
          "type": "text",
          "text": "<recent perception log segment (<30s)>\nTrigger: <trigger source>"
        }
      ]
    }
  ],
  "tools": [
    {
      "name": "speak",
      "description": "Say something to the user. Only call this if there is something genuinely useful to say. Stay silent by not calling this tool.",
      "input_schema": {
        "type": "object",
        "properties": {
          "text": { "type": "string", "description": "What to say aloud. Keep it brief — 1–2 sentences." }
        },
        "required": ["text"]
      }
    }
  ],
  "tool_choice": { "type": "auto" }
}
```

**FLAG mechanism:** If Claude invokes `speak(text: "...")` → banti speaks. If Claude returns `stop_reason: "end_turn"` with no tool call → silence. Claude's reasoning over the full context is the response head.

### SSE streaming and tool-input extraction

Claude's streaming API emits these SSE event types for a tool-use response:

```
event: content_block_start   → { "type": "tool_use", "name": "speak" }  (tool call begins)
event: content_block_delta   → { "type": "input_json_delta", "partial_json": "..." }  (incremental JSON string)
event: content_block_stop    → tool call complete
event: message_delta         → { "stop_reason": "tool_use" | "end_turn" }
```

The `partial_json` fragments form the JSON encoding of `{ "text": "..." }`, streamed incrementally. The implementation must accumulate these fragments and extract the value of the `"text"` key as it streams:

1. Accumulate `partial_json` fragments into a buffer
2. Once `"text":"` has been seen in the buffer, yield all subsequent characters until the closing unescaped `"` as `AgentStreamEvent.speakChunk` fragments
3. On `content_block_stop` → emit `AgentStreamEvent.speakDone`
4. On `message_delta` with `stop_reason: "end_turn"` and no tool call seen → emit `AgentStreamEvent.silent`

### Sentence-boundary chunking for TTS

`CognitiveCoreActor` accumulates `speakChunk` fragments into a sentence buffer and forwards a `SpeakChunkEvent` when a sentence boundary is detected:

- **Accumulate** fragments into `var sentenceBuffer: String`
- **Flush condition:** `sentenceBuffer` ends with `.`, `!`, or `?` **AND** `sentenceBuffer.count >= 15` (minimum to avoid flushing "Hi." as a 3-char chunk)
- **Also flush** when `speakDone` arrives, unconditionally (drain remainder)
- **Emit** `SpeakChunkEvent(text: sentenceBuffer.trimmingCharacters(in: .whitespaces), epoch: currentEpoch)` and clear buffer

### Barge-in path

```
TurnStartedEvent received (and streamTask != nil OR as unconditional guard):
  → streamTask?.cancel()
  → streamTask = nil
  → epoch += 1
  → publish InterruptEvent(epoch: epoch)
  → sentenceBuffer = ""
```

If `TurnStartedEvent` fires when no LLM call is in flight (`streamTask == nil`): still increment epoch and publish `InterruptEvent`. This is deliberate — it signals `StreamingTTSActor` to flush any residual buffered audio from a prior utterance.

### `AgentResponseEvent` for memory write-back

`CognitiveCoreActor` holds a `var pendingTurnText: String = ""`. When handling `TurnEndedEvent`, capture `pendingTurnText = event.text` before launching the LLM stream task. The task captures `pendingTurnText` by value at task creation time, so it remains valid even if a subsequent turn arrives before `speakDone`.

After `speakDone`, publish:
```swift
AgentResponseEvent(
    userText: triggerSource == "user_speech" ? pendingTurnText : "",
    responseText: accumulatedSpeakText,
    sourceModule: ModuleID("cognitive-core")
)
```
For proactive triggers, `userText` is empty string. `MemoryWriteBackActor` will write a one-sided entry; this is acceptable — the memory sidecar can distinguish context-triggered entries from speech-response entries by the empty `user_text` field.

`AgentResponseEvent` needs a new designated initializer that accepts `sourceModule` as a parameter (instead of hard-coding `"agent-bridge"`).

---

## Component 3: StreamingTTSActor

**Replaces:** `TTSActor`

### `CartesiaWebSocketProvider` protocol

```swift
/// Abstracts the Cartesia WebSocket so tests can inject a stub.
protocol CartesiaWebSocketProvider: Sendable {
    /// Opens a new WebSocket session. Returns an AsyncStream of raw PCM Data chunks.
    func connect() async throws -> AsyncThrowingStream<Data, Error>
    /// Send a text chunk (continue: true) or flush (continue: false, empty text).
    func send(text: String, contextID: String, continuing: Bool) async throws
    /// Close the WebSocket cleanly.
    func disconnect() async
}
```

### Responsibilities

1. Maintains a `CartesiaWebSocketProvider` connection (reconnects on drop with exponential backoff: 1s, 2s, 4s, max 30s)
2. Consumes `SpeakChunkEvent`s and forwards text chunks to Cartesia
3. Plays received PCM audio via `AVAudioEngine` + `AVAudioPlayerNode`
4. On `InterruptEvent`: sets epoch = event.epoch, sends flush, drains audio buffer
5. Reports `health: .degraded` during reconnect backoff

### Cartesia WebSocket protocol

**Connect:**
```
wss://api.cartesia.ai/tts/websocket?api_key=<key>&cartesia_version=2025-04-16
```

**Context ID:** A new `UUID` string is generated when the first `SpeakChunkEvent` for a new utterance arrives (i.e., after `InterruptEvent` clears the previous context or on the first chunk of the session). All chunks for the same utterance share the same `contextID`.

**Send per chunk** (on `SpeakChunkEvent` with `event.epoch == self.epoch`):
```json
{
  "model_id": "sonic-3",
  "transcript": "<chunk text>",
  "context_id": "<utterance UUID>",
  "continue": true,
  "voice": { "mode": "id", "id": "<voice_id>" },
  "output_format": { "container": "raw", "encoding": "pcm_f32le", "sample_rate": 44100 }
}
```

**Send on interrupt or end of utterance:**
```json
{ "transcript": "", "context_id": "<utterance UUID>", "continue": false }
```

**Receive:**
- `{ "type": "chunk", "data": "<base64 PCM>" }` → decode, epoch-gate, schedule on `AVAudioPlayerNode`
- `{ "type": "done" }` → utterance complete, clear `currentContextID`

### Epoch gate

```swift
// On SpeakChunkEvent received:
guard event.epoch == self.epoch else { return }   // discard stale chunks
// → send to Cartesia

// On InterruptEvent received:
self.epoch = event.epoch                           // SET (not increment)
send(text: "", contextID: currentContextID, continuing: false)
currentContextID = nil
playerNode.stop()
// drain scheduled buffers
```

### Audio playback

- `AVAudioEngine` with a single `AVAudioPlayerNode`
- PCM format: `Float32`, 44100Hz, mono
- Incoming base64 PCM chunks: decode → `AVAudioPCMBuffer` → `playerNode.scheduleBuffer(_:completionHandler:)` for gapless streaming
- On interrupt: `playerNode.stop()`, flush all scheduled buffers

### Reconnect on WebSocket drop

1. Mark `health = .degraded(reason: "WebSocket disconnected")`
2. Discard in-flight utterance: clear `currentContextID`. Do NOT increment `self.epoch` here — `StreamingTTSActor` never owns the epoch counter. Any remaining stale `SpeakChunkEvent`s from before the disconnect will be discarded by the existing epoch gate once the connection drops.
3. Attempt reconnect with backoff: 1s → 2s → 4s → 8s → max 30s
4. On success: mark `health = .healthy`, resume listening for `SpeakChunkEvent`
5. The interrupted utterance is **not replayed** — the user will get silence or a new response from the next trigger

---

## New Event Types

### `SpeakChunkEvent`
```swift
struct SpeakChunkEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID   // "cognitive-core"
    let text: String             // sentence-complete chunk (>= 15 chars or final drain)
    let epoch: Int               // epoch at time of generation
}
```

### `InterruptEvent`
```swift
struct InterruptEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID   // "cognitive-core"
    let epoch: Int               // new epoch value (CognitiveCoreActor's epoch after increment)
}
```

---

## Data Flow

```
ScreenDescriptionEvent / SceneDescriptionEvent / ActiveAppEvent / AXFocusEvent / TranscriptSegmentEvent
  → PerceptionLogActor  (rolling log: age-evict >90s, cap at 50)
  → CognitiveCoreActor  (trigger check + debounce per source)
      → Claude API streaming (prompt-cached older segment, fresh recent segment, tool-use FLAG)
          speak tool call → accumulate partial_json → sentence-boundary chunks
              → SpeakChunkEvent(text, epoch)
                  → StreamingTTSActor → Cartesia WS (with context_id) → PCM → AVAudioEngine

TurnEndedEvent
  → CognitiveCoreActor  (always triggers, 0s interval)
      → same Claude path above

TurnStartedEvent
  → CognitiveCoreActor
      → cancel streamTask (if any)
      → epoch += 1
      → publish InterruptEvent(epoch)
  → StreamingTTSActor
      → epoch = event.epoch
      → send { continue: false } to Cartesia
      → drain + stop AVAudioPlayerNode

AgentResponseEvent (published by CognitiveCoreActor on speakDone)
  → MemoryWriteBackActor (unchanged)
```

---

## Configuration (env vars)

| Key | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | required | Claude API key |
| `CLAUDE_MODEL` | `claude-haiku-4-5-20251001` | Model for cognitive core (default is Haiku for cost; upgrade to Opus for quality) |
| `CLAUDE_MAX_TOKENS` | `256` | Max response tokens |
| `SCREEN_PROACTIVE_THRESHOLD` | `0.3` | Min changeDistance to trigger proactive screen response |
| `SCENE_PROACTIVE_THRESHOLD` | `0.3` | Min changeDistance to trigger proactive scene response |
| `COGNITIVE_SCREEN_INTERVAL` | `5` | Min seconds between screen-triggered calls |
| `COGNITIVE_SCENE_INTERVAL` | `10` | Min seconds between scene-triggered calls |
| `COGNITIVE_APP_INTERVAL` | `5` | Min seconds between app-switch-triggered calls |
| `PERCEPTION_LOG_MAX_ENTRIES` | `50` | Max log entries |
| `PERCEPTION_LOG_WINDOW_SECONDS` | `90` | Age eviction threshold |
| `CARTESIA_API_KEY` | required | Cartesia API key |
| `CARTESIA_VOICE_ID` | `694f9389-aac1-45b6-b726-9d9369183238` | Cartesia voice ID |

---

## What is NOT changing

- `TurnDetectorActor` — unchanged; still owns speech segmentation and publishes `TurnEndedEvent` / `TurnStartedEvent`
- `MemoryWriteBackActor` — subscribes to `AgentResponseEvent`; receives entries from `CognitiveCoreActor`
- All perception actors (camera, screen, microphone, AX) — unchanged
- `EventHubActor`, `ModuleSupervisorActor`, `ConfigActor` — unchanged
- Bootstrap dependency registration — updated for new actor names

---

## Testing approach

### `PerceptionLogActor`
- Entry age eviction: insert entries at t=0 and t=91s; verify t=0 entry removed
- Cap eviction: insert 51 entries rapidly; verify oldest removed, count == 50
- AXFocus deduplication: insert two AXFocus events with identical (non-nil) app/role/title; verify single entry with updated timestamp. Insert two with `elementTitle == nil`; verify two distinct entries appended.
- Segment split: entries at 10s and 50s ago; verify correct partition at 30s boundary
- Formatted output: snapshot test against expected string

### `CognitiveCoreActor`
- Inject stub `AgentLLMProvider`
- Trigger debounce: fire two `ScreenDescriptionEvent`s 2s apart; verify only one Claude call made
- `TurnEndedEvent` bypasses debounce: fire immediately after prior call; verify two calls made
- Tool-call path: stub returns `[.speakChunk("Hello "), .speakChunk("world."), .speakDone]`; verify `SpeakChunkEvent`s published and `AgentResponseEvent` published at end
- Silent path: stub returns `[.silent]`; verify no `SpeakChunkEvent` or `AgentResponseEvent`
- Barge-in: start streaming, fire `TurnStartedEvent`; verify task cancelled, `InterruptEvent` published with incremented epoch, `sentenceBuffer` cleared
- Barge-in with no active call: fire `TurnStartedEvent` when idle; verify `InterruptEvent` still published

### `StreamingTTSActor`
- Inject stub `CartesiaWebSocketProvider`
- Epoch gate: send `SpeakChunkEvent(epoch: 0)` after `InterruptEvent(epoch: 1)`; verify chunk discarded (no `send` call on stub)
- Interrupt flush: send two chunks, then `InterruptEvent`; verify `{ continue: false }` sent, `playerNode.stop()` called
- `context_id` consistency: all chunks for one utterance share same UUID; new UUID after interrupt
- Reconnect: stub throws on `connect()`; verify backoff delays, `health == .degraded` during backoff, `health == .healthy` on success

### Integration
- Mock all providers; simulate `TurnEndedEvent` → verify `SpeakChunkEvent`s → verify `AgentResponseEvent`
- Simulate rapid barge-in mid-stream; verify only new-epoch chunks reach audio
