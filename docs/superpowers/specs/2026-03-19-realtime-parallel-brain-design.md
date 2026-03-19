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
        │     → Cartesia WebSocket → PCM chunks → AVAudioEngine
        │     First word: ~300-400ms
        │
        └──── Track 2: REASONING ───────────────────────────────
              Graphiti query ─┐
                              ├── asyncio.gather (parallel)
              mem0 query ─────┘
              → Claude Opus 4.6 → streams SSE sentences
              → Cartesia queue (plays after Track 1 finishes)
              First word: ~2-3s (but Track 1 already spoke)
```

### Three layers fixed simultaneously

1. **Model layer** — Cerebras `gpt-oss-120b` (~3000 tok/s) for reflex; Claude Opus 4.6 for reasoning
2. **Streaming layer** — LLM streams SSE sentences → Cartesia WebSocket streams PCM chunks → audio starts per-sentence
3. **Trigger layer** — Deepgram final transcript fires directly into BrainLoop; removes 2s poll delay for speech events

## Components

### Python sidecar — `/brain/stream` (replaces `/brain/decide`)

New SSE endpoint. Accepts `track: "reflex" | "reasoning"` in request body.

**Reflex track:**
- No memory fetch
- Calls Cerebras `gpt-oss-120b` via OpenAI-compatible SDK (`base_url=https://api.cerebras.ai/v1`)
- Streams tokens, detects sentence boundaries server-side
- Emits SSE events: `{"type": "sentence", "text": "..."}` per sentence, `{"type": "done"}` at end

**Reasoning track:**
- Fetches Graphiti + mem0 concurrently via `asyncio.gather`
- Calls Claude Opus 4.6 (existing Anthropic SDK, `stream=True`)
- Same SSE sentence emission

**SSE format:**
```
data: {"type": "sentence", "text": "Hey, I see you've been debugging for a while."}

data: {"type": "done"}
```

Sentence boundary detection: split on `.`, `!`, `?` followed by whitespace or end-of-stream, minimum 4 words to avoid fragments.

### Swift — `BrainLoop`

On trigger, fires two concurrent `Task`s:

```swift
Task { await streamTrack(.reflex) }
Task { await streamTrack(.reasoning) }
```

`streamTrack` reads SSE from `/brain/stream`, parses sentence events, calls `speaker.streamSpeak(sentence, track: track)`.

**Cooldown:** Both tracks share `lastSpoke`. A new trigger is suppressed if cooldown hasn't elapsed. Track 1 sets `lastSpoke` when it fires its first sentence. Track 2 is cooldown-exempt (already authorized by the same trigger).

**Speech trigger change:** `DeepgramStreamer` gains a `onFinalTranscript: ((String) -> Void)?` callback. `BrainLoop` registers on startup and calls `evaluate(reason: "speech")` directly — no 2s poll delay for speech. Poll loop retained only for face/emotion/heartbeat events (reduced to 5s since speech is now event-driven).

### Swift — `CartesiaSpeaker`

New method: `streamSpeak(_ text: String, track: TrackPriority)`

- **Track 1 (reflex)**: plays immediately, interrupts any pending Track 2 items
- **Track 2 (reasoning)**: queued behind Track 1

**Cartesia WebSocket:**
- One persistent `URLSessionWebSocketTask` per session (not per sentence)
- On `streamSpeak`: send JSON message `{"type": "speak", "transcript": text, "voice": {...}, "output_format": {...}}`
- Receive binary frames (raw PCM chunks), feed directly into `AVAudioEngine` as they arrive
- First PCM chunk arrives ~100-150ms after sending sentence

Existing `playSpeech` / `/tts/bytes` REST path removed. `makeBuffer` helper retained (used to assemble partial PCM chunks into playable segments).

## Data Flow — Speech Event End-to-End

```
Deepgram fires final transcript
    │
    └─► BrainLoop.onFinalTranscript()           0ms
            │
            ├─► Task { /brain/stream reflex }   fires immediately
            │       Cerebras gpt-oss-120b
            │       ~100ms first token
            │       sentence: "Hey, I see you're debugging—"
            │           └─► CartesiaSpeaker.streamSpeak()
            │                   Cartesia WebSocket
            │                   ~100ms first PCM chunk
            │                   ← USER HEARS FIRST WORD ~300ms
            │
            └─► Task { /brain/stream reasoning }  fires simultaneously
                    asyncio.gather(Graphiti, mem0)  ~300-800ms
                    Opus 4.6 streams
                    sentences queue in CartesiaSpeaker
                    ← plays after Track 1 finishes
```

## What Is Not Changing

- `PerceptionContext`, `Deduplicator`, `AXReader`
- Face, screen, gesture, emotion analyzers
- Memory ingestion pipeline (`/memory/ingest`, `/memory/reflect`)
- `IdentityStore`, `SpeakerResolver`, `FaceIdentifier`
- `AVAudioEngine` setup in `CartesiaSpeaker` (just changes how PCM data arrives)
- Existing `/brain/decide` endpoint kept as fallback during transition, removed after

## New Dependencies

- **Cerebras SDK**: OpenAI-compatible, add `base_url` override. No new Python package needed if `openai` SDK already present (just point at Cerebras endpoint).
- **`CEREBRAS_API_KEY`** env var added to `.env`
- Cartesia WebSocket: no new Swift package, uses `URLSessionWebSocketTask` (Foundation, already available)

## Open Questions (deferred to implementation)

- Sentence boundary minimum word count: 4 words proposed, tune during testing
- If Track 1 produces nothing useful (silent decision), should Track 2 still play? Yes — Track 2 is independent.
- Cartesia WebSocket reconnect strategy on drop: exponential backoff, max 3 retries, fall back to REST `/tts/bytes` if all fail
