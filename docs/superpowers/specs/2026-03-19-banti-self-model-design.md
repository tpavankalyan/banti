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
| `SelfSpeechLog` | Efference copy — registers utterances before audio; tracks playback end; answers "is this transcript mine?" | New actor |
| `BantiVoice` | Single output identity — wraps CartesiaSpeaker; writes to log + buffer simultaneously | New actor |
| `ConversationBuffer` | Attributed turn history — `[(speaker, text, timestamp)]` | New actor |
| `SpeakerAttributor` | Attribution gate — checks Deepgram transcripts against SelfSpeechLog | New struct |
| `PerceptionContext` | `speech:` removed from fields and from `PerceptionObservation`; `snapshotJSON()` becomes ambient-only | Modified |
| `DeepgramStreamer` | Removes `context.update(.speech(state))` call — only fires `onFinalTranscript` callback | Modified |
| `BrainStreamBody` | `recent_speech: [String]` → `conversation_history: [ConversationTurnDTO]` + `ambient_context` | Modified |
| `BrainLoop` | Uses `ConversationBuffer`; routes transcripts through `SpeakerAttributor`; preserves interruption logic | Modified |
| `SelfModel` | No code change — `snapshotJSON()` is automatically ambient-only once `speech:` is removed from `PerceptionContext` | Passively updated |
| `AXReader` / Screen analyzers | Filter output through `SelfSpeechLog.suppressSelfEcho()` before updating context | Modified |
| `MemoryEngine` | Constructs and wires new actors in correct dependency order | Modified |

---

## New Components

### `SelfSpeechLog` (actor)

Maintains a ring buffer of banti's registered utterances with timestamps. Tracks when the last audio playback ended. Answers two questions: "is this incoming transcript my own echo?" and "does this screen text contain what I recently said?"

```swift
// Core interface
func register(text: String)           // sets isCurrentlyPlaying = true
func markPlaybackEnded()              // called by BrainLoop.streamTrack after the full SSE response
func isSelfEcho(transcript: String, arrivedAt: Date) -> Bool
func suppressSelfEcho(in text: String) -> String

// Internal state
private var entries: [(normalizedText: String, registeredAt: Date)]
private var lastPlaybackEndedAt: Date?
private var isCurrentlyPlaying: Bool = false  // true from first register() until markPlaybackEnded()
```

**Attribution logic in `isSelfEcho`:**
1. Normalize both strings (lowercase, strip punctuation)
2. **Playback gate:** `isCurrentlyPlaying || (lastPlaybackEndedAt != nil && arrivedAt ≤ lastPlaybackEndedAt! + 5.0s)` → candidate. `isCurrentlyPlaying` is set to `true` by `register()` (first sentence of a response) and cleared to `false` by `markPlaybackEnded()` (called after the last sentence in the SSE loop). This spans the full multi-sentence response as a single window. The 5s post-playback tail covers: TTS synthesis latency (~0.3–1s) + Deepgram transcription latency + room acoustic decay.
3. **Fuzzy match:** word-level Jaccard similarity ≥ 0.6 between normalized transcript and any registered entry → `.selfEcho`
4. If playback gate passes but `entries` is empty (cold-start edge case) → `.selfEcho` (conservative)
5. Entries purged after 2 minutes; ring buffer capped at 30 entries

**`suppressSelfEcho` logic for screen/AX text:**
Normalize both the registered texts and the input (lowercase, strip punctuation). Check if any normalized registered phrase of ≥ 5 words appears as a substring in the normalized input. Strip matching spans. Normalized matching (not verbatim) handles chat UIs that add punctuation, wrapping, or name prefixes. Minimum 5-word threshold avoids false positives on common short phrases.

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
// Public interface
func say(_ text: String, track: TrackPriority) async
func isPlaying() async -> Bool          // async func — not computed property (actor isolation)
func cancelTrack(_ track: TrackPriority) async

// Implementation of say() — called once per SSE sentence
func say(_ text: String, track: TrackPriority) async {
    await selfSpeechLog.register(text: text)              // 1. efference copy — before audio
    await conversationBuffer.addBantiTurn(text)           // 2. conversation record
    await cartesiaSpeaker.streamSpeak(text, track: track) // 3. actual audio
    // NOTE: markPlaybackEnded() is NOT called here — it is called by
    // BrainLoop.streamTrack() after the full SSE loop completes, so the
    // suppression window covers the entire multi-sentence response as one unit.
}

func markPlaybackEnded() async {
    await selfSpeechLog.markPlaybackEnded()               // opens 5s tail window
}
```

`isPlaying()` is an `async func` (not a computed `var`) because accessing `cartesiaSpeaker.isPlaying` crosses actor isolation boundaries. `BrainLoop.streamTrack()` calls `bantiVoice.say()` instead of `speaker.streamSpeak()` directly. `BantiVoice` holds references to `SelfSpeechLog`, `ConversationBuffer`, and `CartesiaSpeaker`.

`BantiVoice` is exposed as an `internal` property on `MemoryEngine` (matching the existing access level pattern for `cartesiaSpeaker`), accessible via `@testable import` in tests.

---

### `SpeakerAttributor` (struct)

Lightweight attribution gate. Stateless — all state lives in `SelfSpeechLog`.

```swift
enum Source { case human, selfEcho }

func attribute(
    _ transcript: String,
    arrivedAt: Date,
    selfLog: SelfSpeechLog
) async -> Source
```

**Logic:**
```
if await selfLog.isSelfEcho(transcript, arrivedAt) → .selfEcho
else                                               → .human
```

All timing state (`isCurrentlyPlaying`, `lastPlaybackEndedAt`) lives inside `SelfSpeechLog`. `SpeakerAttributor` needs no `wasPlaying` parameter — `isSelfEcho`'s playback gate already captures whether banti is currently speaking or in the post-playback tail. `wasPlaying` is still captured by `BrainLoop.onFinalTranscript` separately for interruption detection only, not attribution.

---

## Modified Components

### `PerceptionContext`

- **Remove:** `speech: SpeechState?` from stored properties
- **Remove:** `.speech(SpeechState)` case from `PerceptionObservation` enum
- **Modify:** `snapshotJSON()` emits only: `face`, `emotion`, `pose`, `gesture`, `screen`, `activity`, `sound`, `person`

Speech is now exclusively in `ConversationBuffer`. The two channels — conversational and ambient — are fully separated. `SelfModel` is unaffected by code: since `speech:` is removed from `PerceptionContext`, `snapshotJSON()` automatically produces ambient-only snapshots, making `SelfModel.reflect()` correct without any changes to `SelfModel.swift`.

---

### `DeepgramStreamer`

**Remove:** `await context.update(.speech(state))` call in `handleMessage`. The `.speech` observation no longer exists. `DeepgramStreamer` retains `onFinalTranscript` callback and continues calling it for final transcripts — this is its only output path. Since the `.speech` update was the only usage of `context` in `DeepgramStreamer`, removing it leaves the `context` parameter with no remaining usages; it can be removed from `DeepgramStreamer.init` in the same PR.

---

### `BrainStreamBody`

```swift
// Removed
let recent_speech: [String]
let last_spoke_text: String?        // derivable from conversation_history

// Added
let conversation_history: [ConversationTurnDTO]
let ambient_context: String         // context.snapshotJSON() — no speech
let last_banti_utterance: String?   // convenience — last banti turn text

// Unchanged
let track: String
let is_interruption: Bool
let current_speech: String?         // see note below
let last_spoke_seconds_ago: Double
```

```swift
struct ConversationTurnDTO: Encodable {
    let speaker: String      // "banti" or "human"
    let text: String
    let timestamp: Double    // unix timestamp
}
```

**`current_speech` tracking:** `BrainLoop.streamTrack()` continues to set `currentlySpeaking = text` immediately before calling `bantiVoice.say(text, track)`, exactly as today it sets it before `speaker.streamSpeak()`. No mechanism change — the assignment simply moves one line earlier in the call site.

---

### `BrainLoop`

**Remove:** `recentTranscripts: [String]`, `lastSpokeText: String?`

**Add to init:** `bantiVoice: BantiVoice`, `selfSpeechLog: SelfSpeechLog`, `conversationBuffer: ConversationBuffer`

New init signature:
```swift
public init(context: PerceptionContext, sidecar: MemorySidecar,
            bantiVoice: BantiVoice, selfSpeechLog: SelfSpeechLog,
            conversationBuffer: ConversationBuffer, logger: Logger)
```

**Modified `onFinalTranscript` — preserves interruption logic:**
```swift
func onFinalTranscript(_ transcript: String) async {
    // Capture isPlaying BEFORE attribution — needed for interruption detection below
    let wasPlaying = await bantiVoice.isPlaying()
    // Attribution: SpeakerAttributor uses SelfSpeechLog's internal timing state (no wasPlaying needed)
    let source = await SpeakerAttributor().attribute(
        transcript, arrivedAt: Date(),
        selfLog: selfSpeechLog
    )
    guard source == .human else { return }
    await conversationBuffer.addHumanTurn(transcript)
    // Preserve existing interruption detection: human spoke while banti was playing
    let isInterruption = wasPlaying && BrainLoop.isInterruptionCandidate(transcript)
    await evaluate(reason: "speech: \(transcript)", isInterruption: isInterruption)
}
```

**Modified `streamTrack`:**
- Builds `BrainStreamBody` from `conversationBuffer.recentTurns()` and `context.snapshotJSON()` (ambient-only)
- In the SSE sentence loop: sets `currentlySpeaking = text`, then calls `bantiVoice.say(text, track: track)`
- After the SSE loop completes (all sentences spoken): calls `await bantiVoice.markPlaybackEnded()` if any sentences were spoken — this opens the 5s acoustic tail window for the full response as a unit
- `lastSpokeText` replaced by `conversationBuffer.lastBantiUtterance()` for `last_banti_utterance` field

### `AXReader` and Screen Analyzers

Before updating `PerceptionContext`, pass text through `await selfSpeechLog.suppressSelfEcho(in:)`. The normalized-cleaned text is what gets stored in context.

### `MemoryEngine`

**New construction order (all synchronous in `init`):**
```swift
// Constructed in dependency order:
let selfSpeechLog    = SelfSpeechLog()
let conversationBuffer = ConversationBuffer()
let cartesiaSpeaker  = CartesiaSpeaker(engine: engine, logger: logger)
let bantiVoice       = BantiVoice(cartesiaSpeaker: cartesiaSpeaker,
                                   selfSpeechLog: selfSpeechLog,
                                   conversationBuffer: conversationBuffer,
                                   logger: logger)
let brainLoop        = BrainLoop(context: context, sidecar: sidecar,
                                  bantiVoice: bantiVoice,
                                  selfSpeechLog: selfSpeechLog,
                                  conversationBuffer: conversationBuffer,
                                  logger: logger)
```

`bantiVoice` is `internal` on `MemoryEngine` (same access level as the existing `cartesiaSpeaker`). The transcript callback wiring in `MemoryEngine.start()` is unchanged — it still calls `await audioRouter.setTranscriptCallback { await loop.onFinalTranscript($0) }`.

---

## Data Flow

```
SPEAKING PATH (per-sentence loop in streamTrack)
─────────────
for each sentence from SSE:
  currentlySpeaking = sentence                            [0] in-flight tracking (unchanged)
  → bantiVoice.say(sentence, track)
      ├─ selfSpeechLog.register(sentence)                 [1] efference copy — sets isCurrentlyPlaying=true
      ├─ conversationBuffer.addBantiTurn(sentence)        [2] conversation record
      └─ cartesiaSpeaker.streamSpeak(sentence, track)     [3] audio out

after SSE loop completes (all sentences spoken):
  → bantiVoice.markPlaybackEnded()                        [4] clears isCurrentlyPlaying, opens 5s tail


LISTENING PATH
──────────────
MicrophoneCapture → AudioRouter → DeepgramStreamer
  DeepgramStreamer.handleMessage():
    • NO longer calls context.update(.speech(...))
    • fires onFinalTranscript callback only
  BrainLoop.onFinalTranscript(transcript):
    wasPlaying = await bantiVoice.isPlaying()   ← for interruption detection only
    → SpeakerAttributor.attribute(transcript, now, selfLog)
        ├─ .selfEcho → discard silently
        └─ .human   → conversationBuffer.addHumanTurn(transcript)
                     → evaluate(reason: "speech: ...",
                                isInterruption: wasPlaying && isInterruptionCandidate(transcript))


SCREEN / AX PATH
────────────────
ScreenCapture / AXReader
  raw text captured
    → await selfSpeechLog.suppressSelfEcho(in: rawText) → cleaned (normalized match)
    → context.update(.screen(cleaned))


BRAIN CALL PATH
───────────────
BrainLoop.streamTrack() builds BrainStreamBody:
  conversation_history: conversationBuffer.recentTurns(10)    ← attributed, clean
  ambient_context:      context.snapshotJSON()                ← no speech field
  last_banti_utterance: conversationBuffer.lastBantiUtterance()
  current_speech:       currentlySpeaking                     ← unchanged
  last_spoke_seconds_ago, is_interruption                     ← unchanged
```

---

## Edge Cases

### Human interrupts while banti is speaking

`wasPlaying = true` at the time the transcript arrives. `SpeakerAttributor` checks `isSelfEcho` — the human's transcript doesn't match anything in `SelfSpeechLog` (Jaccard < 0.6) → `.human`. `onFinalTranscript` calls `evaluate(isInterruption: true)` because `wasPlaying && isInterruptionCandidate(transcript)`. The `shouldTrigger` cooldown is bypassed for interruptions as today.

### Deepgram paraphrases TTS output

"Let me check on that for you" vs. "let me check that for you" → Jaccard = 7/8 = 0.875. Well above 0.6 threshold.

### TTS synthesis latency + Deepgram transcription latency stack

Banti's audio for sentence N: registered at T, TTS synthesis ~300ms, playback duration D, `markPlaybackEnded` at T+D+300ms (approximate). Deepgram transcription of banti's audio arrives at ~T+D+300ms+200ms. `lastPlaybackEndedAt + 5.0s` window covers both latencies with ~4.5s of headroom. For multi-sentence responses, each sentence's audio plays sequentially; `markPlaybackEnded` is called after the last sentence, so the window stays open correctly.

### Screen shows a chat UI with the full conversation

`suppressSelfEcho` uses normalized (lowercase, no punctuation) substring matching. Chat UI name prefixes (`"Banti: ..."`) are stripped along with the sentence because the normalized registered text appears as a substring of the normalized screen line. Minimum 5-word threshold prevents false positives on short common phrases.

### `SelfSpeechLog` empty on cold start or TTS unavailable

`isSelfEcho` returns false for all transcripts → everything treated as human. Safe default.

### `DeepgramStreamer` context dependency after removing `.speech` update

Once `context.update(.speech(state))` is removed, `DeepgramStreamer` no longer needs the `context` parameter. The dependency can be removed from `DeepgramStreamer.init` in the same PR to reduce coupling, but this is an optional cleanup — omitting it is not a correctness issue.

---

## Python Sidecar Changes

The `/brain/stream` endpoint receives an updated `BrainStreamBody`. The HTTP transport layer (URL, method, auth headers, SSE response format) is unchanged. Only the JSON request body structure changes:

1. **Rename `snapshot_json` → `ambient_context`** in request parsing (same content, different key)
2. **Replace `recent_speech: [str]`** with `conversation_history: list[dict]`, each dict: `{"speaker": "banti"|"human", "text": "...", "timestamp": 1234567890.0}`
3. **Update prompt assembly:** render conversation history as dialogue (`Human: ...\nBanti: ...`) rather than a flat list
4. **`last_spoke_text`** → `last_banti_utterance` (renamed field, same semantics)

The `track` field, SSE sentence/done event format, and all other sidecar logic are unchanged.

---

## What Does Not Change

- `CartesiaSpeaker` internals — `BantiVoice` wraps it, no internal changes needed
- `AudioRouter` / `MicrophoneCapture` — PCM pipeline unchanged
- `MemorySidecar` Swift HTTP transport — same URL, method, and headers; JSON body field names change (see above)
- Heartbeat and poll event loops in `BrainLoop`
- `FaceIdentifier`, `SpeakerResolver`, `MemoryIngestor`, `SoundClassifier`
- `TrackPriority` reflex/reasoning parallel track logic
- `SelfModel` — no code change; passively benefits from `speech:` removal in `PerceptionContext`

---

## Open Questions (deferred to implementation)

1. Should `SpeakerAttributor` log suppressed transcripts at debug level for observability?
2. Should `ConversationBuffer` persist across restarts (e.g. written to sidecar) or always start fresh?
3. Should the Jaccard threshold (0.6), tail window (5.0s), and suppression minimum phrase length (5 words) be configurable via environment variables?
4. Can `DeepgramStreamer`'s `context` dependency be removed in this PR, or deferred to a follow-up cleanup?
