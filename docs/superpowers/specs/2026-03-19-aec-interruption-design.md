# Acoustic Echo Cancellation + Interrupt-Aware Brain

**Date:** 2026-03-19
**Status:** Approved

## Problem

banti transcribes its own TTS output. The current workaround — a mute gate that suppresses mic audio to Deepgram while `CartesiaSpeaker.isPlaying` — prevents self-echo but has two flaws:

1. Interruptions are silently dropped (user speech during banti's playback is never transcribed).
2. It is architecturally a hack, not signal processing.

## Human Analogy

The brain solves this with two mechanisms:

- **Corollary discharge (efference copy):** Before speaking, the motor cortex sends a predicted sensory consequence to the auditory cortex. The auditory cortex subtracts this prediction from incoming audio. Only the error signal (unexpected sounds) passes through — so someone else talking over you still gets through.
- **Cognitive yield decision:** When an interruption is detected, a higher-level decision determines whether to yield, finish the thought, or push back — based on context, not a hard rule.

banti already has the architecture for both: macOS hardware AEC maps to corollary discharge; the reflex + reasoning two-track brain maps to the cognitive yield decision.

## Design

### 1. Shared AVAudioEngine (Corollary Discharge)

**Root cause of the mute-gate hack:** `MicrophoneCapture` and `CartesiaSpeaker` own separate `AVAudioEngine` instances. macOS's `setVoiceProcessingEnabled(true)` requires both input and output on the same engine to reference the playback signal for echo cancellation.

**Fix:** Extract the engine into a shared instance created in `main.swift`, injected into both components.

```
main.swift
  let sharedEngine = AVAudioEngine()
  MicrophoneCapture(engine: sharedEngine, ...)     ← input tap + voice processing
  MemoryEngine(engine: sharedEngine, ...)
    └── CartesiaSpeaker(engine: sharedEngine, ...) ← playerNode attaches here
```

`MicrophoneCapture.startCapture()` calls `try inputNode.setVoiceProcessingEnabled(true)` on the shared engine's input node before `engine.start()`. With `playerNode` on the same engine, macOS has the playback reference signal needed for AEC. The mute gate in `AudioRouter` is removed entirely.

### 2. Interrupt-Aware BrainLoop (Cognitive Yield Decision)

With AEC working, Deepgram fires transcripts even while banti is speaking. `BrainLoop.onFinalTranscript()` becomes the interruption entry point.

**Cooldown bypass for interruptions.** The 10-second cooldown guard (`shouldTrigger`) prevents re-triggering on stale context. For interruptions, the user explicitly spoke — it always warrants evaluation. `onFinalTranscript` passes `isInterruption: true` to `evaluate()`, which bypasses the cooldown check.

**Interruption context passed to the LLM.** `BrainStreamBody` gains two new fields:

- `is_interruption: Bool` — signals to the brain that banti was mid-speech.
- `current_speech: String?` — what banti was saying when cut off.

`BrainLoop` tracks `currentlySpeaking: String?`, updated with each sentence streamed by either track. On interruption, this becomes `current_speech` in the brain request.

The existing `evaluate()` flow — cancel current tracks, fire reflex + reasoning — is unchanged. The yield/continue/push-back decision is left entirely to the LLM: seeing `is_interruption`, `current_speech`, and `recent_speech`, it responds naturally, exactly as a human would. No hard-coded yield logic.

### 3. Mute Gate Removal

`AudioRouter.speakingGate`, `setMuteGate()`, and the mute check in `dispatch()` are removed. `CartesiaSpeaker.isPlaying` is removed. `MemoryEngine.start()` no longer wires the gate. The `AudioRouter` returns to its original clean state.

## Files Changed

| File | Change |
|---|---|
| `main.swift` | Create shared `AVAudioEngine`; inject into `MicrophoneCapture` and `MemoryEngine` |
| `MicrophoneCapture` | Accept shared engine via init; call `setVoiceProcessingEnabled(true)` before start |
| `CartesiaSpeaker` | Accept shared engine via init; remove internal `engine` property |
| `MemoryEngine` | Accept shared engine; pass to `CartesiaSpeaker`; remove mute gate wiring |
| `AudioRouter` | Remove `speakingGate`, `setMuteGate()`, mute check in `dispatch()` |
| `BrainLoop` | Track `currentlySpeaking`; detect interruption in `onFinalTranscript`; bypass cooldown; pass interruption context |
| `BrainStreamBody` | Add `is_interruption: Bool`, `current_speech: String?` |

## Testing

**Unit tests:**
- `BrainLoop.shouldTrigger`: returns `true` when `isInterruption: true` regardless of cooldown elapsed.
- `BrainLoop.onFinalTranscript` while `speaker.isPlaying`: `BrainStreamBody` has `is_interruption: true` and `current_speech` set.
- `BrainStreamBody` encoding: new fields serialize correctly.

**Build test:**
- Shared engine starts cleanly with both `playerNode` attached and voice processing enabled on input node.

**Manual smoke test:**
- Speak while banti responds → voice comes through cleanly; banti's next response reflects the interruption.
- Speak after banti finishes → normal behaviour unchanged.
