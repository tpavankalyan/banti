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

**Fix:** A single `AVAudioEngine` is created in `main.swift` and injected into both components.

```
main.swift
  let sharedEngine = AVAudioEngine()
  MemoryEngine(engine: sharedEngine, ...)
    └── CartesiaSpeaker(engine: sharedEngine, ...)  ← attach + connect in init
  MicrophoneCapture(engine: sharedEngine, ...)       ← start() called after MemoryEngine init
```

**`CartesiaSpeaker` init:**

`CartesiaSpeaker` accepts `engine: AVAudioEngine` in its initializer. In `init`, it immediately calls `engine.attach(playerNode)` and `engine.connect(playerNode, to: engine.mainMixerNode, format: fixedFormat)` where `fixedFormat` is `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22050, channels: 1, interleaved: true)` — the same format used in `makeBuffer`. `AVAudioEngine` will handle any internal Float32 conversion transparently; using the same Int16 format throughout keeps the code consistent. This must happen **before** `engine.start()` is ever called, because macOS requires the node graph to be fully connected before the engine starts — connecting nodes to a running engine requires stopping and restarting it.

`CartesiaSpeaker` never calls `engine.start()`. The current `engineStarted: Bool` flag and its lazy-setup block in `playBuffer()` are removed entirely — setup is done eagerly in `init`. In `cancelTrack(.reflex)`, the `if engineStarted { playerNode.play() }` guard becomes an unconditional `playerNode.play()` (the node must be restarted after stop, regardless of setup state).

**Engine `start()` ownership:**

`engine.start()` is called exactly once, owned by `MicrophoneCapture.startCapture()`. `main.swift` ensures `MemoryEngine.init` (and therefore `CartesiaSpeaker.init`) completes before `micCapture.start()` is called.

**Voice processing:**

`MicrophoneCapture.startCapture()` calls `try inputNode.setVoiceProcessingEnabled(true)` on the shared engine's input node before `engine.start()`. With `playerNode` attached and connected to the same engine, macOS has the playback reference signal needed for AEC. The mute gate in `AudioRouter` is removed entirely.

### 2. Interrupt-Aware BrainLoop (Cognitive Yield Decision)

With AEC working, Deepgram fires transcripts even while banti is speaking. `BrainLoop.onFinalTranscript()` becomes the interruption entry point.

**Interruption detection:**

`onFinalTranscript` checks `await speaker.isPlaying` — `isPlaying` is an `internal` property on `CartesiaSpeaker` (not public; only used by `BrainLoop` for this check).

**Cooldown bypass for interruptions:**

`shouldTrigger` gains a new parameter:

```swift
public static func shouldTrigger(lastSpoke: Date?, isInterruption: Bool, now: Date = Date()) -> Bool {
    if isInterruption { return true }
    guard let lastSpoke else { return true }
    return now.timeIntervalSince(lastSpoke) > cooldownSeconds
}
```

Existing `BrainLoopTests` calls to `shouldTrigger` pass the new `isInterruption: false` argument — no behaviour change for existing tests.

**AEC convergence guard:** To prevent rapid-fire re-triggers during the first few hundred milliseconds before the echo canceller fully converges (when Deepgram may still produce short fragments of banti's own voice), interruption bypass only applies when the transcript contains **2 or more words**. Single-word transcripts during playback are treated as noise. This check is in `onFinalTranscript` before calling `evaluate`.

**Interruption context passed to the LLM:**

`BrainStreamBody` gains two new fields:

```swift
let is_interruption: Bool
let current_speech: String?
```

`BrainLoop` tracks `currentlySpeaking: String?`. It is updated **just before** each `await speaker.streamSpeak(text, track: track)` call in `streamTrack()`. Both tracks update it; since `BrainLoop` is an actor, there is no data race. It is reset to `nil` at the start of `evaluate()` (before cancelling the in-flight tracks). When `onFinalTranscript` detects an interruption, it captures the current value of `currentlySpeaking` and passes it to `evaluate(reason:isInterruption:currentSpeech:)`, which includes it in `BrainStreamBody`.

The existing `evaluate()` flow — cancel current tracks, fire reflex + reasoning — is unchanged. The yield/continue/push-back decision is left entirely to the LLM: seeing `is_interruption`, `current_speech`, and `recent_speech`, it responds naturally.

### 3. Mute Gate Removal

`AudioRouter.speakingGate`, `setMuteGate()`, and the mute check in `dispatch()` are removed. `MemoryEngine.start()` no longer wires the gate. `CartesiaSpeaker.isPlaying` is demoted from `public` to `internal` — this is safe because the only cross-module consumer was the mute gate in `main.swift` (executable target `banti`); once the gate is removed, no code outside `BantiCore` accesses `isPlaying`. Both changes must be applied together to avoid a compiler error.

## Files Changed

| File | Change |
|---|---|
| `main.swift` | Create shared `AVAudioEngine`; pass to `MemoryEngine` and `MicrophoneCapture`; `MemoryEngine` init completes before `micCapture.start()` |
| `MicrophoneCapture` | Accept shared engine via init; remove internal `engine`; call `setVoiceProcessingEnabled(true)` before start; owns the single `engine.start()` call in `startCapture()` |
| `CartesiaSpeaker` | Accept shared engine via init; remove internal `engine`; call `engine.attach(playerNode)` + `engine.connect(...)` eagerly in init using fixed format (22050 Hz Int16 mono); remove `engineStarted` guard from `playBuffer()`; never call `engine.start()`; `isPlaying` becomes `internal` |
| `MemoryEngine` | Accept shared engine via init; pass to `CartesiaSpeaker` init; remove mute gate wiring from `start()` |
| `AudioRouter` | Remove `speakingGate`, `setMuteGate()`, mute check in `dispatch()` |
| `BrainLoop` | Track `currentlySpeaking`; detect interruption + 2-word guard in `onFinalTranscript`; update `shouldTrigger` signature with `isInterruption: Bool`; pass interruption context to `evaluate` and `BrainStreamBody` |
| `BrainStreamBody` | Add `is_interruption: Bool`, `current_speech: String?` |
| `BrainLoopTests` | Update `shouldTrigger` call sites to pass `isInterruption: false`; add tests for interruption bypass, 2-word guard, `BrainStreamBody` encoding |
| `CartesiaSpeakerTests` | Update `init` call sites to pass shared engine |

## Testing

**Unit tests (`BrainLoopTests`):**
- `shouldTrigger(lastSpoke:isInterruption:)`: returns `true` when `isInterruption: true` regardless of cooldown elapsed.
- `shouldTrigger`: existing cooldown tests pass unchanged with new `isInterruption: false` argument.
- `onFinalTranscript` while `speaker.isPlaying`, transcript ≥ 2 words: `BrainStreamBody` has `is_interruption: true` and `current_speech` set.
- `onFinalTranscript` while `speaker.isPlaying`, single-word transcript: cooldown not bypassed.
- `BrainStreamBody` encoding: `is_interruption` and `current_speech` fields serialize correctly.

**Manual integration test:**
- Launch banti. Verify no `[error]` or `[warn]` logs related to `AVAudioEngine` start or voice processing.
- Verify `microphone capture started` log appears (engine started successfully).
- Speak while banti is responding: voice is transcribed cleanly; banti's next response reflects the interruption.
- Speak after banti finishes: normal behaviour unchanged.
- Verify no self-echo loop: banti does not respond to its own voice.
