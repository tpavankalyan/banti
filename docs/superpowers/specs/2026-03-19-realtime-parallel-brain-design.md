# Real-Time Parallel Brain Architecture

**Date:** 2026-03-19
**Status:** Approved

## Problem

The current pipeline is fully serial: poll (up to 2s) → `/brain/decide` (Opus 4.6, non-streaming, 1-3s) → Cartesia `/tts/bytes` (non-streaming, 0.5-1.5s). Total latency from trigger to first audio word: **4-7 seconds**. This feels nothing like natural conversation.

## Goal

First audio word within **~300-400ms** of a trigger. Natural, flowing speech. Deep memory-backed follow-up without blocking the initial response.

## Architecture

Two parallel tracks fire on every trigger:

```
EVENT FIRES (speech final / new person / emotion spike)
        │
        ├──── Track 1: REFLEX ──────────────────────────────────
        │     Cerebras gpt-oss-120b (no memory)
        │     Snapshot only → streams SSE sentences
        │     → Cartesia WebSocket A → PCM chunks → AVAudioEngine
        │     First word: ~300-400ms
        │
        └──── Track 2: REASONING ───────────────────────────────
              Graphiti query ─┐
                              ├── asyncio.gather (parallel)
              mem0 query ─────┘
              → Claude Opus 4.6 → streams SSE sentences
              → Cartesia WebSocket B → queued after Track 1 audio
              First word: ~2-3s (but Track 1 already spoke)
```

### Three layers fixed simultaneously

1. **Model layer** — Cerebras `gpt-oss-120b` (~3000 tok/s) for reflex; Claude Opus 4.6 for reasoning
2. **Streaming layer** — LLM streams SSE sentences → Cartesia WebSocket streams PCM chunks → audio starts per-sentence
3. **Trigger layer** — Deepgram final transcript fires directly into BrainLoop; removes 2s poll delay for speech events

## Components

### Python sidecar — `/brain/stream` (replaces `/brain/decide`)

New SSE endpoint implemented as a FastAPI `StreamingResponse` with an `async def` generator (no new packages; Starlette's `StreamingResponse` is already available via FastAPI).

```python
from fastapi.responses import StreamingResponse

@app.post("/brain/stream")
async def brain_stream(req: BrainStreamRequest):
    return StreamingResponse(
        _generate(req),
        media_type="text/event-stream"
    )
```

**Request body schema** (`BrainStreamRequest` Pydantic model — new, replaces `BrainDecideRequest`):

```json
{
  "track": "reflex" | "reasoning",
  "snapshot_json": "<JSON string from context.snapshotJSON()>",
  "recent_speech": ["<transcript1>", "<transcript2>"],
  "last_spoke_seconds_ago": 42.0,
  "last_spoke_text": "<last thing banti said, or null>"
}
```

**Reflex track:**
- No memory fetch
- Calls Cerebras `gpt-oss-120b` via `openai` SDK with `base_url="https://api.cerebras.ai/v1"` and `api_key=os.environ["CEREBRAS_API_KEY"]`
- Streaming system prompt:
  ```
  You are banti, an ambient AI assistant watching over the user's Mac.
  Speak in short, natural sentences — like a thoughtful friend nearby.
  React only to what's genuinely happening right now. 1-2 sentences max.
  Respond with plain prose only. No JSON. No markdown. No preamble.
  If there is truly nothing worth saying, respond with exactly: [silent]
  ```
- User message: formatted string of `snapshot_json` + `recent_speech`
- Streams tokens; detects sentence boundaries in the generator
- Emits `{"type": "sentence", "text": "..."}` per complete sentence; `{"type": "silent"}` if response is `[silent]`; `{"type": "done"}` at end

**Reasoning track:**
- Fetches Graphiti + mem0 concurrently via `asyncio.gather` (same logic as existing `brain_decide`)
- Calls Claude Opus 4.6 via Anthropic SDK with `stream=True`
- **New streaming prompt** (replaces the JSON-output prompt in `memory.py` for this endpoint):
  ```
  You are banti. You just heard the reflex track respond. Add depth, memory,
  or context if you have something genuinely useful to say. Speak naturally
  in 1-3 sentences. Plain prose only — no JSON, no preamble.
  If you have nothing to add, respond with exactly: [silent]
  ```
- Same sentence boundary detection and SSE emission as reflex track

**SSE format** (both tracks):
```
data: {"type": "sentence", "text": "Hey, I see you've been debugging for a while."}

data: {"type": "done"}
```

**Sentence boundary detection** (in the async generator):
- Accumulate streamed tokens in a buffer
- Emit a sentence when buffer matches `[.!?]\s` and word count ≥ 4
- At stream end (`done`): flush any remaining buffer as a sentence regardless of word count (so "Got it." still plays); discard only if entirely whitespace/punctuation
- If response is `[silent]`, emit `{"type": "silent"}` then `{"type": "done"}`, yield nothing else

**Timeouts:**
- Close stream with `{"type": "error"}` if no token arrives within 8s of request start
- Close stream if total duration exceeds 20s

### Swift — `BrainLoop`

On trigger, fires two concurrent `Task`s:

```swift
Task { await streamTrack(.reflex) }
Task { await streamTrack(.reasoning) }
```

`streamTrack` opens an SSE connection to `/brain/stream`, parses sentence events, calls `speaker.streamSpeak(sentence, track:)`.

**`lastSpoke` and `lastSpokeText` updates:**
- `lastSpoke = Date()` is set at trigger time (before either Task fires), preserving cooldown guarantee
- `lastSpokeText` is set by Track 1 (reflex): concatenated as sentences arrive, finalized when Track 1's `done` event fires
- If Track 2 (reasoning) also speaks, `lastSpokeText` is overwritten with Track 2's concatenated sentences when its `done` fires
- This ensures `lastSpokeText` always holds the most recent thing banti said

**Rapid trigger / cancellation policy:**
- `evaluate()` stores the two active Task handles as `var activeReflexTask: Task<Void,Never>?` and `var activeReasoningTask: Task<Void,Never>?`
- On new trigger: cancel both handles before spawning new Tasks
- `Task.cancel()` propagates through `Task.isCancelled` checks in `streamTrack` (check after each SSE read)
- Cancelling a Task does not flush already-scheduled AVAudioEngine buffers — call `speaker.cancelTrack(.reasoning)` before cancelling Track 2's Task (see `CartesiaSpeaker` below)
- Track 1 is interrupted the same way: cancel + `speaker.cancelTrack(.reflex)`

**Cooldown:** Both tracks share `lastSpoke`. Track 2 does not re-check cooldown. A new external trigger before cooldown expires is suppressed (both tracks suppressed, same as today).

**Speech trigger change:** `DeepgramStreamer` gains:
```swift
public var onFinalTranscript: (@Sendable (String) async -> Void)?
```
`BrainLoop.start()` registers:
```swift
let brain = self  // strong reference — BrainLoop owns the loop lifetime
deepgramStreamer.onFinalTranscript = { transcript in
    await brain.evaluate(reason: "speech: \(transcript)")
}
```
Strong reference is correct: `DeepgramStreamer` is owned by the same `AppDelegate`/coordinator as `BrainLoop`, so the lifetime is tied. No `weak` capture needed (actors cannot be weakly referenced).

**Transcript accumulation:** Move out of `pollEvents` entirely. `onFinalTranscript` callback appends to `recentTranscripts` directly before calling `evaluate`. `pollEvents` (now 5s interval) no longer touches `recentTranscripts`. This eliminates double-append. Heartbeat stays at 15s.

### Swift — `CartesiaSpeaker`

**Two dedicated WebSocket connections** — one per track, to avoid any need to demultiplex binary PCM frames:
- `reflexSocket: URLSessionWebSocketTask?` — used exclusively for Track 1
- `reasoningSocket: URLSessionWebSocketTask?` — used exclusively for Track 2
- Both created lazily on first `streamSpeak` call for each track
- PCM frames received on each socket belong unambiguously to their track

**WebSocket message format** (send per sentence, same fields as existing REST body):
```json
{
  "model_id": "sonic-2",
  "transcript": "<sentence text>",
  "voice": { "mode": "id", "id": "<CARTESIA_VOICE_ID>" },
  "output_format": { "container": "raw", "encoding": "pcm_s16le", "sample_rate": 22050 }
}
```

**Receiving:** Cartesia sends multiple binary WebSocket frames per sentence (~4KB each). Each binary frame is passed to `makeBuffer` and immediately scheduled via `playerNode.scheduleBuffer`. This is per-frame, not per-sentence — audio starts playing within ~100ms of the first frame arriving.

**Queue / priority:**
- Track 1 (reflex): schedules immediately on `reflexSocket`
- Track 2 (reasoning): queued in `pendingReasoningBuffers`. Playback of Track 2 begins only after Track 1's `reflexSocket` signals completion of its current sentence set (tracked via `playerNode.scheduleBuffer` completion callback count)
- New Track 1 mid-Track-2: pauses Track 2 playback (stops scheduling from `pendingReasoningBuffers`), plays Track 1, resumes Track 2 afterward

**`cancelTrack(_ track: TrackPriority)`:**
- For `.reflex`: calls `playerNode.stop()`, then `playerNode.play()` to reset; clears any pending reflex buffers
- For `.reasoning`: clears `pendingReasoningBuffers` (discards unscheduled frames); does not interrupt a reasoning sentence already mid-playback (let it finish the current ~4KB frame)

**`finishCurrentSentence()`** (called by BrainLoop before launching new Track 1 if old Track 1 is speaking):
- Returns when `isSpeakingReflex == false`; implemented as a spin-wait with 50ms Task.sleep intervals, max 2s timeout then proceeds anyway
- `isSpeakingReflex` is set to `false` in the `scheduleBuffer` completion callback when the last reflex frame for the current sentence has played back

New method signatures:
```swift
public func streamSpeak(_ text: String, track: TrackPriority) async
public func cancelTrack(_ track: TrackPriority)
public func finishCurrentSentence() async
```

**Fallback:** `playSpeech` (REST `/tts/bytes`) is retained as fallback if WebSocket fails to establish (3 attempts, exponential backoff 0.5s/1s/2s) or drops mid-stream. Fallback logged at `[warn]`. `makeBuffer` works for both paths.

**Timeout per sentence:** If no binary frame arrives within 5s of sending a WebSocket message, abandon that sentence and proceed to next queued item.

## Data Flow — Speech Event End-to-End

```
Deepgram fires final transcript
    │
    └─► BrainLoop.onFinalTranscript()           0ms
            recentTranscripts.append(transcript)
            lastSpoke = Date()
            │
            ├─► Task { /brain/stream reflex }   fires immediately
            │       Cerebras gpt-oss-120b
            │       ~100ms first token
            │       sentence: "Hey, I see you're debugging—"
            │           └─► speaker.streamSpeak(.reflex)
            │                   reflexSocket → Cartesia
            │                   ~100ms first PCM frame
            │                   ← USER HEARS FIRST WORD ~300ms
            │
            └─► Task { /brain/stream reasoning }  fires simultaneously
                    asyncio.gather(Graphiti, mem0)  ~300-800ms
                    Opus 4.6 streams sentences
                    → speaker.streamSpeak(.reasoning)
                    → pendingReasoningBuffers
                    ← drains after reflex audio done
```

## What Is Not Changing

- `PerceptionContext`, `Deduplicator`, `AXReader`
- Face, screen, gesture, emotion analyzers
- Memory ingestion pipeline (`/memory/ingest`, `/memory/reflect`)
- `IdentityStore`, `SpeakerResolver`, `FaceIdentifier`
- `AVAudioEngine` and `AVAudioPlayerNode` setup in `CartesiaSpeaker`
- Existing `/brain/decide` endpoint — kept throughout transition, removed after `/brain/stream` is validated

## New Dependencies

- **Cerebras API:** OpenAI-compatible. Uses existing `openai` Python SDK with `base_url` override. Add `CEREBRAS_API_KEY` to `.env`.
- **Cartesia WebSocket:** No new Swift package. Uses `URLSessionWebSocketTask` (Foundation).
- **`TrackPriority` enum:** New Swift type in `BantiCore`, no external package.
- **No new Python packages** required.
