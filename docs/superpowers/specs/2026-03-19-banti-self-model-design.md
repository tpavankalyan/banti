# Banti Self-Model & Conversation Architecture Design

**Date:** 2026-03-19
**Status:** Approved
**Problem:** Banti enters infinite loops by reacting to its own voice (acoustic), its own text on screen (visual), and its own prior utterances misidentified as human input (semantic). All three failure modes stem from the same root: no persistent self-model woven into the perception pipeline.

---

## Problem Statement

Three concurrent self-echo failure modes:

1. **Acoustic self-echo** — `MicrophoneCapture` picks up banti's TTS output; `DeepgramStreamer` transcribes it; `BrainLoop` reacts to banti's own voice as if a human spoke.
2. **Visual self-echo** — Banti's response text appears on screen; `AXReader`/`GPT4oScreenAnalyzer` reads it back into `PerceptionContext.screen`; the brain server sees banti's own words as ambient context.
3. **Semantic confusion** — `recent_speech: [String]` sent to the brain server is unattributed; the LLM cannot distinguish banti's prior utterances from human speech; it responds to its own history.

Root cause: banti has no efference copy mechanism. It doesn't register what it's about to say before saying it, so it cannot suppress self-generated signals in the sensory pipeline.

---

## Human Brain Analogy

The design mirrors three neuroscientific mechanisms:

- **Efference copy / corollary discharge** — The motor cortex sends a prediction to the auditory cortex before speech occurs. Expected self-generated sounds are suppressed before they become perception. This is why you cannot tickle yourself.
- **Phonological working memory** — You know what you will say before you say it. The brain registers the utterance as intention, not as heard output.
- **Conversation vs. observation segregation** — The prefrontal cortex maintains a clear model of who-said-what (conversation) entirely separately from environmental perception (ambient context). Screen content is peripheral vision — it informs but does not participate in dialogue.

---

## Architecture Overview

### Core Invariant

`ConversationBuffer` is the single source of truth for what was said and by whom. It is populated in exactly two places:
- `BantiVoice.say()` — for banti turns
- `SpeakerAttributor` — for verified human turns

No raw Deepgram transcript ever reaches the brain loop without attribution. No speech content ever enters `PerceptionContext`.

### Component Map

| Component | Role | Status |
|---|---|---|
| `SelfSpeechLog` | Efference copy — registers utterances before audio; answers "is this transcript mine?" | New actor |
| `BantiVoice` | Single output identity — wraps CartesiaSpeaker; writes to log + buffer simultaneously | New actor |
| `ConversationBuffer` | Attributed turn history — `[(speaker, text, timestamp)]` | New actor |
| `SpeakerAttributor` | Attribution gate — checks Deepgram transcripts against SelfSpeechLog | New struct |
| `PerceptionContext` | `speech:` removed; `snapshotJSON()` becomes ambient-only | Modified |
| `BrainStreamBody` | `recent_speech: [String]` → `conversation_history: [ConversationTurnDTO]` + `ambient_context` | Modified |
| `BrainLoop` | Uses `ConversationBuffer`; routes transcripts through `SpeakerAttributor` | Modified |
| `AXReader` / Screen analyzers | Filter output through `SelfSpeechLog.suppressSelfEcho()` before updating context | Modified |

---

## New Components

### `SelfSpeechLog` (actor)

Maintains a ring buffer of banti's registered utterances with timestamps. Answers two questions: "is this incoming transcript my own echo?" and "does this screen text contain what I recently said?"

```swift
// Core interface
func register(text: String)
func isSelfEcho(transcript: String, arrivedAt: Date) -> Bool
func suppressSelfEcho(in text: String) -> String
func hasAnyActiveEntry() -> Bool
```

**Attribution logic in `isSelfEcho`:**
1. Normalize both strings (lowercase, strip punctuation)
2. **Timing gate:** if `arrivedAt` falls within `[registeredAt, registeredAt + estimatedDuration + 3.0s]` → candidate
3. **Fuzzy match:** word-level Jaccard similarity ≥ 0.6 between normalized transcript and registered text → `.selfEcho`
4. If timing gate passes but no text registered yet (edge case on first word) → `.selfEcho` (conservative)
5. Entries purged after 2 minutes

**Estimated duration:** `wordCount / 2.5` seconds (average TTS speaking rate).

**`suppressSelfEcho` logic:** strips any phrase ≥ 5 contiguous words from recent registered texts found verbatim (case-insensitive) in the input string. Minimum 5-word threshold avoids false positives on common short phrases.

Ring buffer capped at 30 entries.

---

### `ConversationBuffer` (actor)

The attributed conversation history. Replaces `recentTranscripts: [String]` in `BrainLoop`.

```swift
enum Speaker { case banti, human }

struct ConversationTurn {
    let speaker: Speaker
    let text: String
    let timestamp: Date
}

func addBantiTurn(_ text: String)
func addHumanTurn(_ text: String)
func recentTurns(limit: Int = 10) -> [ConversationTurn]
func lastBantiUtterance() -> String?
```

Capped at 30 turns (drops oldest from front). `addBantiTurn` called only from `BantiVoice`. `addHumanTurn` called only from `SpeakerAttributor`.

---

### `BantiVoice` (actor)

The single output identity. All speech exits through here.

```swift
func say(_ text: String, track: TrackPriority) async {
    selfSpeechLog.register(text: text)              // 1. efference copy — before audio
    conversationBuffer.addBantiTurn(text)           // 2. conversation record
    await cartesiaSpeaker.streamSpeak(text, track)  // 3. actual audio
}

var isPlaying: Bool { await cartesiaSpeaker.isPlaying }
func cancelTrack(_ track: TrackPriority) async { ... }
```

`BrainLoop.streamTrack()` calls `bantiVoice.say()` instead of `speaker.streamSpeak()` directly. `BantiVoice` owns references to both `SelfSpeechLog` and `ConversationBuffer`.

---

### `SpeakerAttributor` (struct)

Lightweight attribution gate. Stateless — all state lives in `SelfSpeechLog`.

```swift
enum Source { case human, selfEcho }

func attribute(
    _ transcript: String,
    arrivedAt: Date,
    selfLog: SelfSpeechLog,
    isPlaying: Bool
) async -> Source
```

**Logic:**
```
if isPlaying AND selfLog.isSelfEcho(transcript, arrivedAt) → .selfEcho
if isPlaying AND !selfLog.hasAnyActiveEntry()              → .human   // banti hasn't registered anything recently
if selfLog.isSelfEcho(transcript, arrivedAt)               → .selfEcho
else                                                       → .human
```

`isPlaying` alone is not sufficient to suppress (would block human interruptions). The fuzzy match against `SelfSpeechLog` is required as the discriminator.

---

## Modified Components

### `PerceptionContext`

- **Remove:** `speech: SpeechState?` and its `.speech` case from `PerceptionObservation`
- **Modify:** `snapshotJSON()` no longer includes speech. Emits only: `face`, `emotion`, `pose`, `gesture`, `screen`, `activity`, `sound`, `person`

Speech is now exclusively in `ConversationBuffer`. The two channels — conversational and ambient — are fully separated.

### `BrainStreamBody`

```swift
// Removed
let recent_speech: [String]
let last_spoke_text: String?   // derivable from conversation_history

// Added
let conversation_history: [ConversationTurnDTO]
let ambient_context: String          // snapshotJSON() — no speech
let last_banti_utterance: String?    // convenience field

// Unchanged
let track: String
let is_interruption: Bool
let current_speech: String?
let last_spoke_seconds_ago: Double
```

```swift
struct ConversationTurnDTO: Encodable {
    let speaker: String      // "banti" or "human"
    let text: String
    let timestamp: Double    // unix timestamp
}
```

### `BrainLoop`

**Remove:** `recentTranscripts: [String]`, `lastSpokeText: String?`

**Add:** `conversationBuffer: ConversationBuffer`, `selfSpeechLog: SelfSpeechLog` (both injected via init or owned by `BantiVoice`)

**Modified `onFinalTranscript`:**
```swift
func onFinalTranscript(_ transcript: String) async {
    let source = await SpeakerAttributor().attribute(
        transcript, arrivedAt: Date(),
        selfLog: selfSpeechLog,
        isPlaying: await bantiVoice.isPlaying
    )
    guard source == .human else { return }
    await conversationBuffer.addHumanTurn(transcript)
    await evaluate(reason: "speech: \(transcript)")
}
```

**Modified `streamTrack`:** builds `BrainStreamBody` from `conversationBuffer.recentTurns()` and `context.snapshotJSON()`. Calls `bantiVoice.say()`.

### `AXReader` and Screen Analyzers

Before updating `PerceptionContext`, pass text through `selfSpeechLog.suppressSelfEcho(in:)`. The cleaned text is what gets stored in context.

### `MemoryEngine`

Constructs `SelfSpeechLog`, `ConversationBuffer`, and `BantiVoice` and injects them into `BrainLoop`. `BantiVoice` wraps the existing `CartesiaSpeaker`.

---

## Data Flow

```
SPEAKING PATH
─────────────
BrainLoop.streamTrack() receives sentence from SSE
  → bantiVoice.say(sentence, track)
      ├─ selfSpeechLog.register(sentence)          [1] efference copy — before audio
      ├─ conversationBuffer.addBantiTurn(sentence) [2] conversation record
      └─ cartesiaSpeaker.streamSpeak(sentence)     [3] audio out


LISTENING PATH
──────────────
MicrophoneCapture → AudioRouter → DeepgramStreamer
  final transcript arrives at BrainLoop.onFinalTranscript()
    → SpeakerAttributor.attribute(transcript, now, selfLog, isPlaying)
        ├─ .selfEcho → discard silently
        └─ .human   → conversationBuffer.addHumanTurn(transcript)
                     → BrainLoop.evaluate(reason: "speech: ...")


SCREEN / AX PATH
────────────────
ScreenCapture / AXReader
  raw text captured
    → selfSpeechLog.suppressSelfEcho(in: rawText) → cleaned
    → context.update(.screen(cleaned))


BRAIN CALL PATH
───────────────
BrainLoop.streamTrack() builds BrainStreamBody:
  conversation_history: conversationBuffer.recentTurns(10)  ← attributed
  ambient_context:      context.snapshotJSON()              ← no speech
  last_banti_utterance: conversationBuffer.lastBantiUtterance()
```

---

## Edge Cases

### Human interrupts while banti is speaking

`isPlaying = true` but the incoming transcript doesn't match anything in `SelfSpeechLog` (it's a new human utterance). `SpeakerAttributor` classifies it `.human`. The brain triggers an interruption via the existing `isInterruptionCandidate` (≥2 words) path. No change needed to interruption logic.

### Deepgram paraphrases TTS output

Deepgram normalizes what it hears. "Let me check on that for you" vs. "let me check that for you" → Jaccard = 7/8 = 0.875. Well above 0.6 threshold.

### TTS finishes but room echo/reverb lingers

The 3s post-playback tail in the timing window covers acoustic decay in most environments.

### Screen shows a chat UI with the full conversation

`suppressSelfEcho` uses a minimum 5-word contiguous phrase match. Short common phrases don't trigger suppression. Full sentences banti said are stripped. Name prefixes in the UI (`"Banti: ..."`) don't affect matching since the registered text doesn't include them.

### `SelfSpeechLog` empty on cold start or when TTS is unavailable

`isSelfEcho` returns false for all transcripts → everything treated as human. Safe default: banti may respond to itself once on startup if TTS replays a prior session, but `ConversationBuffer` is also empty so there's no stale history to react to.

---

## Python Sidecar Changes

The `/brain/stream` endpoint receives an updated `BrainStreamBody`. Required changes:

1. **Rename `snapshot_json` → `ambient_context`** in request parsing
2. **Replace `recent_speech: [str]`** with `conversation_history: list[dict]` where each dict has `speaker`, `text`, `timestamp`
3. **Update prompt assembly:** render conversation history as dialogue (`Human: ...\nBanti: ...`) rather than a flat list
4. **`last_spoke_text`** → derive from `last_banti_utterance` field or last banti turn in history

The `track` field, SSE response format, and all other sidecar logic are unchanged.

---

## What Does Not Change

- `CartesiaSpeaker` internals — `BantiVoice` wraps it, no internal changes needed
- `DeepgramStreamer` — attribution happens in `BrainLoop`, not inside Deepgram
- `AudioRouter` / `MicrophoneCapture` — PCM pipeline unchanged
- `MemorySidecar` Swift HTTP client — same interface, different request body fields
- Heartbeat and poll event loops in `BrainLoop`
- `FaceIdentifier`, `SpeakerResolver`, `MemoryIngestor`, `SoundClassifier`
- `TrackPriority` reflex/reasoning parallel track logic

---

## Open Questions (deferred to implementation)

1. Should `SpeakerAttributor` log suppressed transcripts at debug level for observability?
2. Should `ConversationBuffer` persist across restarts (e.g. written to sidecar) or always start fresh?
3. Should the Jaccard threshold (0.6) and tail window (3.0s) be configurable via environment variables?
