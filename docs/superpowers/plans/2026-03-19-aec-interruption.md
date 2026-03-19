# AEC + Interrupt-Aware Brain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mute-gate self-echo hack with macOS hardware AEC via a shared `AVAudioEngine`, and teach `BrainLoop` to detect and contextualise interruptions so the LLM can decide naturally whether to yield, finish, or push back.

**Architecture:** A single `AVAudioEngine` instance is created in `main.swift` and injected into both `CartesiaSpeaker` (which eagerly attaches its `playerNode` in `init`) and `MicrophoneCapture` (which calls `setVoiceProcessingEnabled(true)` before `engine.start()`). macOS AEC then cancels the speaker echo from the mic signal. `BrainLoop.onFinalTranscript` detects mid-speech transcripts, bypasses the cooldown for multi-word interruptions, and passes `is_interruption` + `current_speech` context to the brain LLM.

**Tech Stack:** Swift, AVFoundation (`AVAudioEngine`, `AVAudioPlayerNode`, `setVoiceProcessingEnabled`), XCTest

**Spec:** `docs/superpowers/specs/2026-03-19-aec-interruption-design.md`

---

## File Map

| File | What changes |
|---|---|
| `Sources/BantiCore/AudioRouter.swift` | Remove `speakingGate`, `setMuteGate()`, mute check in `dispatch()` |
| `Sources/BantiCore/CartesiaSpeaker.swift` | Accept `engine: AVAudioEngine` in init; eager attach+connect; remove `engineStarted`; `cancelTrack` unconditional `play()`; `isPlaying` → `internal` |
| `Sources/BantiCore/MicrophoneCapture.swift` | Accept `engine: AVAudioEngine` in init; remove internal engine; call `setVoiceProcessingEnabled(true)`; own `engine.start()` |
| `Sources/BantiCore/MemoryEngine.swift` | Accept `engine: AVAudioEngine` in init; pass to `CartesiaSpeaker`; remove mute gate wiring |
| `Sources/BantiCore/BrainLoop.swift` | `shouldTrigger` gains `isInterruption: Bool`; `evaluate` gains interruption params; `streamTrack` passes them to `BrainStreamBody`; track `currentlySpeaking`; `onFinalTranscript` detects interruptions |
| `Sources/banti/main.swift` | Create `AVAudioEngine`; reorder so `MemoryEngine.init` runs before `micCapture.start()` |
| `Tests/BantiTests/BrainLoopTests.swift` | Update `shouldTrigger` call sites; add interruption + `BrainStreamBody` encoding tests |
| `Tests/BantiTests/CartesiaSpeakerTests.swift` | Pass `AVAudioEngine()` to all `CartesiaSpeaker` init calls |

---

## Task 1: Remove mute gate

**Files:**
- Modify: `Sources/BantiCore/AudioRouter.swift`
- Modify: `Sources/BantiCore/MemoryEngine.swift`
- Modify: `Sources/BantiCore/CartesiaSpeaker.swift`

- [ ] **Step 1: Remove speakingGate from AudioRouter**

In `Sources/BantiCore/AudioRouter.swift`, remove the `speakingGate` property, the `setMuteGate` method, and the mute check in `dispatch`. The file should look like:

```swift
// Remove this line:
private var speakingGate: (@Sendable () async -> Bool)?

// Remove this method entirely:
public func setMuteGate(_ gate: @escaping @Sendable () async -> Bool) {
    speakingGate = gate
}

// In dispatch(), replace:
//   let muted = speakingGate != nil ? await speakingGate!() : false
//   if !muted { await streamer.send(chunk: pcmChunk) }
// with:
if let streamer = deepgram {
    await streamer.send(chunk: pcmChunk)
}
```

After the edit, `dispatch(pcmChunk:)` should be:

```swift
public func dispatch(pcmChunk: Data) async {
    // Stream every chunk to Deepgram (direct await preserves chunk ordering)
    if let streamer = deepgram {
        await streamer.send(chunk: pcmChunk)
    }
    appendToPCMRingBuffer(pcmChunk)

    humeBuffer.append(pcmChunk)
    if humeBuffer.count >= AudioRouter.humeFlushThreshold {
        if let analyzer = hume {
            let segment = humeBuffer
            Task { [weak self] in
                guard let self else { return }
                if let state = await analyzer.analyze(pcmData: segment) {
                    await self.context.update(.voiceEmotion(state))
                }
            }
        }
        humeBuffer = Data()
    }
}
```

- [ ] **Step 2: Remove mute gate wiring from MemoryEngine.start()**

In `Sources/BantiCore/MemoryEngine.swift`, remove these two lines from `start()`:

```swift
// Delete:
let speaker = cartesiaSpeaker
await audioRouter.setMuteGate { await speaker.isPlaying }
```

- [ ] **Step 3: Demote CartesiaSpeaker.isPlaying to internal**

In `Sources/BantiCore/CartesiaSpeaker.swift`, change:

```swift
// Before:
public var isPlaying: Bool { isSpeaking || isSpeakingReflex || playerNode.isPlaying }
// After:
var isPlaying: Bool { isSpeaking || isSpeakingReflex || playerNode.isPlaying }
```

(No access modifier = `internal`, accessible within `BantiCore` module including `BrainLoop`, but not from `main.swift`.)

- [ ] **Step 4: Build and test**

```bash
swift build && swift test
```

Expected: build succeeds, all existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/AudioRouter.swift Sources/BantiCore/MemoryEngine.swift Sources/BantiCore/CartesiaSpeaker.swift
git commit -m "refactor: remove mute gate — AudioRouter, MemoryEngine, CartesiaSpeaker.isPlaying demoted to internal"
```

---

## Task 2: Update shouldTrigger + BrainStreamBody

**Files:**
- Modify: `Sources/BantiCore/BrainLoop.swift`
- Modify: `Tests/BantiTests/BrainLoopTests.swift`

- [ ] **Step 1: Write failing tests**

In `Tests/BantiTests/BrainLoopTests.swift`, add these tests in the `// MARK: - Cooldown` section:

```swift
func testShouldTriggerTrueWhenIsInterruption() {
    // Interruption bypasses cooldown even if spoke very recently
    let justSpoke = Date().addingTimeInterval(-1)
    XCTAssertTrue(BrainLoop.shouldTrigger(lastSpoke: justSpoke, isInterruption: true))
}

func testShouldTriggerFalseWhenNotInterruptionAndWithinCooldown() {
    let recentlySpoke = Date().addingTimeInterval(-5)
    XCTAssertFalse(BrainLoop.shouldTrigger(lastSpoke: recentlySpoke, isInterruption: false))
}
```

And add this test for `BrainStreamBody` encoding in a new `// MARK: - BrainStreamBody` section:

```swift
// MARK: - BrainStreamBody

func testBrainStreamBodyEncodesInterruptionFields() throws {
    let body = BrainStreamBody(
        track: "reflex",
        snapshot_json: "{}",
        recent_speech: [],
        last_spoke_seconds_ago: 5.0,
        last_spoke_text: "hello",
        is_interruption: true,
        current_speech: "I was saying"
    )
    let data = try JSONEncoder().encode(body)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(json["is_interruption"] as? Bool, true)
    XCTAssertEqual(json["current_speech"] as? String, "I was saying")
}

func testBrainStreamBodyEncodesNonInterruptionFields() throws {
    let body = BrainStreamBody(
        track: "reasoning",
        snapshot_json: "{}",
        recent_speech: [],
        last_spoke_seconds_ago: 12.0,
        last_spoke_text: nil,
        is_interruption: false,
        current_speech: nil
    )
    let data = try JSONEncoder().encode(body)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(json["is_interruption"] as? Bool, false)
    // Swift's JSONEncoder encodes nil as JSON null (key present, value NSNull).
    // Test that current_speech is not a string — covers both null and absent cases.
    XCTAssertNil(json["current_speech"] as? String)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter BrainLoopTests
```

Expected: compiler errors about missing `isInterruption` parameter and `BrainStreamBody` missing fields.

- [ ] **Step 3: Update shouldTrigger signature**

In `Sources/BantiCore/BrainLoop.swift`, update `shouldTrigger`:

```swift
public static func shouldTrigger(lastSpoke: Date?, isInterruption: Bool = false, now: Date = Date()) -> Bool {
    if isInterruption { return true }
    guard let lastSpoke else { return true }
    return now.timeIntervalSince(lastSpoke) > cooldownSeconds
}
```

The default `isInterruption: false` means the existing call site in `evaluate()` compiles without change for now.

- [ ] **Step 4: Add is_interruption and current_speech to BrainStreamBody**

In `Sources/BantiCore/BrainLoop.swift`, update `BrainStreamBody`:

```swift
struct BrainStreamBody: Encodable {
    let track: String
    let snapshot_json: String
    let recent_speech: [String]
    let last_spoke_seconds_ago: Double
    let last_spoke_text: String?
    let is_interruption: Bool
    let current_speech: String?
}
```

- [ ] **Step 5: Update the BrainStreamBody construction in streamTrack**

`streamTrack` currently builds `BrainStreamBody` without the new fields. Add them with defaults for now (Task 3 will wire the real values):

```swift
let body = BrainStreamBody(
    track: track.rawValue,
    snapshot_json: snapshot,
    recent_speech: recentTranscripts,
    last_spoke_seconds_ago: BrainLoop.secondsSince(lastSpoke),
    last_spoke_text: lastSpokeText,
    is_interruption: false,       // wired in Task 3
    current_speech: nil           // wired in Task 3
)
```

- [ ] **Step 6: Update existing shouldTrigger test call sites in BrainLoopTests**

The four existing calls to `shouldTrigger` must now compile. Since the parameter has a default value (`isInterruption: false`), no changes are needed — but verify the tests that called `shouldTrigger` with `now:` still compile:

```swift
// This existing test already uses a named `now:` parameter — verify it compiles:
XCTAssertFalse(BrainLoop.shouldTrigger(lastSpoke: exactly10, now: now))
// becomes (with default isInterruption):
XCTAssertFalse(BrainLoop.shouldTrigger(lastSpoke: exactly10, isInterruption: false, now: now))
// OR simply leave it as-is — the default covers it.
```

Update the `testShouldTriggerFalseExactlyAt10Seconds` test to explicitly pass `isInterruption: false` to document intent:

```swift
func testShouldTriggerFalseExactlyAt10Seconds() {
    let now = Date()
    let exactly10 = now.addingTimeInterval(-10)
    XCTAssertFalse(BrainLoop.shouldTrigger(lastSpoke: exactly10, isInterruption: false, now: now))
}
```

- [ ] **Step 7: Run tests to verify they pass**

```bash
swift test --filter BrainLoopTests
```

Expected: all tests pass including new ones.

- [ ] **Step 8: Commit**

```bash
git add Sources/BantiCore/BrainLoop.swift Tests/BantiTests/BrainLoopTests.swift
git commit -m "feat: shouldTrigger isInterruption bypass + BrainStreamBody interruption fields"
```

---

## Task 3: BrainLoop interruption logic

**Files:**
- Modify: `Sources/BantiCore/BrainLoop.swift`
- Modify: `Tests/BantiTests/BrainLoopTests.swift`

- [ ] **Step 1: Write failing test for isInterruptionCandidate**

In `Tests/BantiTests/BrainLoopTests.swift`, add a `// MARK: - Interruption detection` section:

```swift
// MARK: - Interruption detection

func testIsInterruptionCandidateTrueForMultiWord() {
    XCTAssertTrue(BrainLoop.isInterruptionCandidate("hello there"))
}

func testIsInterruptionCandidateFalseForSingleWord() {
    XCTAssertFalse(BrainLoop.isInterruptionCandidate("hello"))
}

func testIsInterruptionCandidateFalseForEmptyString() {
    XCTAssertFalse(BrainLoop.isInterruptionCandidate(""))
}

func testIsInterruptionCandidateTrueForThreeWords() {
    XCTAssertTrue(BrainLoop.isInterruptionCandidate("wait hold on"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter BrainLoopTests.testIsInterruptionCandidate
```

Expected: compiler error — `isInterruptionCandidate` does not exist.

- [ ] **Step 3: Add isInterruptionCandidate static helper**

In `Sources/BantiCore/BrainLoop.swift`, add to the `// MARK: - Pure static helpers` section:

```swift
/// Returns true when the transcript has 2+ words — minimum threshold to treat as an
/// intentional interruption (single-word fragments may be AEC convergence noise).
public static func isInterruptionCandidate(_ transcript: String) -> Bool {
    transcript.split(separator: " ").count >= 2
}
```

- [ ] **Step 4: Run tests to verify isInterruptionCandidate tests pass**

```bash
swift test --filter BrainLoopTests.testIsInterruptionCandidate
```

Expected: all four tests pass.

- [ ] **Step 5: Add currentlySpeaking property and update evaluate/streamTrack**

In `Sources/BantiCore/BrainLoop.swift`:

**Add property** (near the other private vars, around line 31):

```swift
private var currentlySpeaking: String?
```

**Update `evaluate` signature and body** — add `isInterruption` and `currentSpeech` params, reset `currentlySpeaking` at the top, pass context to `streamTrack`:

```swift
private func evaluate(reason: String, isInterruption: Bool = false, currentSpeech: String? = nil) async {
    guard BrainLoop.shouldTrigger(lastSpoke: lastSpoke, isInterruption: isInterruption) else { return }
    guard await sidecar.isRunning else { return }

    // Reset mid-speech tracking before cancelling in-flight tasks
    currentlySpeaking = nil

    // Cancel in-flight tasks from prior trigger
    await speaker.cancelTrack(.reflex)
    await speaker.cancelTrack(.reasoning)
    activeReflexTask?.cancel()
    activeReasoningTask?.cancel()

    lastSpoke = Date()

    logger.log(source: "brain", message: "[\(reason)] firing parallel tracks")

    let brain = self
    activeReflexTask = Task { await brain.streamTrack(.reflex, isInterruption: isInterruption, currentSpeech: currentSpeech) }
    activeReasoningTask = Task { await brain.streamTrack(.reasoning, isInterruption: isInterruption, currentSpeech: currentSpeech) }
}
```

**Update `streamTrack` signature and BrainStreamBody construction**:

```swift
private func streamTrack(_ track: TrackPriority, isInterruption: Bool = false, currentSpeech: String? = nil) async {
    guard await sidecar.isRunning else { return }

    let snapshot = await context.snapshotJSON()
    let body = BrainStreamBody(
        track: track.rawValue,
        snapshot_json: snapshot,
        recent_speech: recentTranscripts,
        last_spoke_seconds_ago: BrainLoop.secondsSince(lastSpoke),
        last_spoke_text: lastSpokeText,
        is_interruption: isInterruption,
        current_speech: currentSpeech
    )
    // ... rest of function unchanged
```

**Update `streamTrack` to set `currentlySpeaking` before each `streamSpeak` call**:

```swift
if event.type == "sentence", let text = event.text, !text.isEmpty {
    spokeSentences.append(text)
    currentlySpeaking = text                              // track for interruption context
    await speaker.streamSpeak(text, track: track)
}
```

- [ ] **Step 6: Update onFinalTranscript to detect interruptions**

```swift
public func onFinalTranscript(_ transcript: String) async {
    BrainLoop.appendTranscript(&recentTranscripts, new: transcript, isFinal: true)

    let interruption = await speaker.isPlaying && BrainLoop.isInterruptionCandidate(transcript)
    let capturedSpeech = interruption ? currentlySpeaking : nil

    await evaluate(
        reason: "speech: \(transcript)",
        isInterruption: interruption,
        currentSpeech: capturedSpeech
    )
}
```

- [ ] **Step 7: Build and test**

```bash
swift build && swift test
```

Expected: build succeeds, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/BantiCore/BrainLoop.swift Tests/BantiTests/BrainLoopTests.swift
git commit -m "feat: BrainLoop interruption detection — currentlySpeaking, isInterruptionCandidate, onFinalTranscript"
```

---

## Task 4: CartesiaSpeaker + MemoryEngine shared engine

**Files:**
- Modify: `Sources/BantiCore/CartesiaSpeaker.swift`
- Modify: `Sources/BantiCore/MemoryEngine.swift`
- Modify: `Tests/BantiTests/CartesiaSpeakerTests.swift`

- [ ] **Step 1: Write failing test for CartesiaSpeaker with injected engine**

In `Tests/BantiTests/CartesiaSpeakerTests.swift`, add:

```swift
func testInitWithSharedEngineDoesNotCrash() {
    let engine = AVAudioEngine()
    // Should not crash — attach+connect happen in init before engine.start()
    let speaker = CartesiaSpeaker(engine: engine, logger: Logger(), apiKey: nil, voiceID: "test")
    XCTAssertFalse(speaker.isAvailable)  // nil apiKey
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter CartesiaSpeakerTests.testInitWithSharedEngineDoesNotCrash
```

Expected: compiler error — `CartesiaSpeaker.init` does not accept an `engine:` parameter.

- [ ] **Step 3: Update CartesiaSpeaker**

Replace the entire `CartesiaSpeaker` init and engine setup. Key changes:

**Properties** — remove `private let engine = AVAudioEngine()` and `private var engineStarted = false`. Add:

```swift
private let engine: AVAudioEngine
```

**New init**:

```swift
public init(engine: AVAudioEngine,
            logger: Logger,
            apiKey: String? = ProcessInfo.processInfo.environment["CARTESIA_API_KEY"],
            voiceID: String = ProcessInfo.processInfo.environment["CARTESIA_VOICE_ID"]
                         ?? "a0e99841-438c-4a64-b679-ae501e7d6091",
            session: URLSession = .shared) {
    self.engine = engine
    self.logger = logger
    self.apiKey = apiKey
    self.voiceID = voiceID
    self.session = session

    // Attach and connect playerNode eagerly — must happen before engine.start().
    // AVAudioEngine requires a complete node graph before start(); connecting after
    // start() would require a stop/restart cycle.
    let fixedFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                    sampleRate: 22050, channels: 1, interleaved: true)!
    engine.attach(playerNode)
    engine.connect(playerNode, to: engine.mainMixerNode, format: fixedFormat)
}
```

**Update `playBuffer`** — remove the `engineStarted` guard entirely:

```swift
private func playBuffer(_ buffer: AVAudioPCMBuffer) {
    playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in }
    if !playerNode.isPlaying { playerNode.play() }
}
```

**Update `cancelTrack(.reflex)`** — remove `engineStarted` guard, unconditional `playerNode.play()`:

```swift
public func cancelTrack(_ track: TrackPriority) async {
    if track == .reflex {
        reflexSocket?.cancel(with: .normalClosure, reason: nil)
        reflexSocket = nil
        isSpeakingReflex = false
        playerNode.stop()
        playerNode.play()   // always restart — node stays stopped until explicitly played
    } else {
        reasoningSocket?.cancel(with: .normalClosure, reason: nil)
        reasoningSocket = nil
        pendingReasoningBuffers.removeAll()
    }
}
```

- [ ] **Step 4: Update MemoryEngine to accept and pass shared engine**

In `Sources/BantiCore/MemoryEngine.swift`, update `init`:

```swift
public init(context: PerceptionContext, audioRouter: AudioRouter, engine: AVAudioEngine, logger: Logger) {
    // ...existing setup...
    self.cartesiaSpeaker = CartesiaSpeaker(engine: engine, logger: logger)
    // ...rest of init unchanged...
}
```

- [ ] **Step 5: Update CartesiaSpeakerTests init call sites**

Every `CartesiaSpeaker(logger:...)` call in the test file must gain an `engine:` argument. Since these tests don't start the engine, a fresh `AVAudioEngine()` per test is fine:

```swift
// Before:
let speaker = CartesiaSpeaker(logger: Logger(), apiKey: nil, voiceID: "test-voice")
// After:
let speaker = CartesiaSpeaker(engine: AVAudioEngine(), logger: Logger(), apiKey: nil, voiceID: "test-voice")
```

Apply this to all init sites in `CartesiaSpeakerTests.swift` (there are 8 of them).

- [ ] **Step 6: Run tests (library target only)**

`swift test` compiles `BantiTests` which depends on `BantiCore`, not on the `banti` executable. `main.swift` is in the `banti` target and will fail to compile until Task 5 updates it — but that does not affect `swift test`.

```bash
swift test
```

Expected: all tests pass. (`swift build` will fail until Task 5 — that is expected.)

- [ ] **Step 7: Commit**

```bash
git add Sources/BantiCore/CartesiaSpeaker.swift Sources/BantiCore/MemoryEngine.swift Tests/BantiTests/CartesiaSpeakerTests.swift
git commit -m "feat: CartesiaSpeaker + MemoryEngine accept shared AVAudioEngine — eager attach/connect in init"
```

---

## Task 5: MicrophoneCapture + main.swift + voice processing

**Files:**
- Modify: `Sources/BantiCore/MicrophoneCapture.swift`
- Modify: `Sources/banti/main.swift`

No unit tests: `MicrophoneCapture` depends on audio hardware. Verified via build + manual integration test.

- [ ] **Step 1: Update MicrophoneCapture to accept shared engine**

In `Sources/BantiCore/MicrophoneCapture.swift`:

**Remove** `private let engine = AVAudioEngine()`.

**Add** stored property and update init:

```swift
private let engine: AVAudioEngine

public init(engine: AVAudioEngine,
            dispatcher: any AudioChunkDispatcher,
            soundClassifier: SoundClassifier,
            logger: Logger) {
    self.engine = engine
    self.dispatcher = dispatcher
    self.soundClassifier = soundClassifier
    self.logger = logger
}
```

**Update `startCapture()`** — call `setVoiceProcessingEnabled(true)` before `engine.start()`, and own the single `start()` call:

```swift
private func startCapture() {
    let inputNode = engine.inputNode

    // Enable macOS hardware AEC. Requires playerNode to already be attached to the
    // same engine (done in CartesiaSpeaker.init via MemoryEngine.init before this is called).
    // macOS uses the engine's output as the echo reference signal — analogous to the
    // brain's corollary discharge suppressing predicted self-generated sound.
    do {
        try inputNode.setVoiceProcessingEnabled(true)
    } catch {
        logger.log(source: "audio", message: "[warn] Voice processing (AEC) unavailable: \(error.localizedDescription)")
    }

    let inputFormat = inputNode.outputFormat(forBus: 0)

    guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        logger.log(source: "audio", message: "[error] Failed to create AVAudioConverter from \(inputFormat) to 16kHz Int16")
        return
    }
    converter = conv

    soundClassifier.setup(inputFormat: inputFormat)

    let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.02)
    inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
        self?.processTap(buffer: buffer)
    }

    do {
        try engine.start()
        logger.log(source: "audio", message: "microphone capture started (\(inputFormat.sampleRate)Hz → 16kHz)")
    } catch {
        logger.log(source: "audio", message: "[error] AVAudioEngine start failed: \(error.localizedDescription)")
        inputNode.removeTap(onBus: 0)
    }
}
```

- [ ] **Step 2: Update MicrophoneCapture.stop()**

The current `stop()` calls `engine.stop()`, which would stop the shared engine and kill `CartesiaSpeaker`'s `playerNode`. Since `MicrophoneCapture` no longer owns the engine, it must not stop it — only remove its tap:

```swift
public func stop() {
    engine.inputNode.removeTap(onBus: 0)
    // Do not call engine.stop() — the engine is shared; its lifecycle is owned by main.swift.
}
```

- [ ] **Step 3: Update main.swift**

The key ordering constraint: `MemoryEngine.init` (which calls `CartesiaSpeaker.init` which calls `engine.attach`/`engine.connect`) must complete **before** `micCapture.start()` (which calls `engine.start()`).

Current order in `main.swift` has `micCapture.start()` on line 45, `MemoryEngine` created on line 48 — this must be swapped.

Replace the audio pipeline + memory layer section with:

```swift
// Audio pipeline
let audioRouter = AudioRouter(context: context, logger: logger)
Task { await audioRouter.configure() }

// Shared audio engine — must be created before either CartesiaSpeaker or MicrophoneCapture.
// CartesiaSpeaker.init (called inside MemoryEngine.init) attaches its playerNode to this engine.
// MicrophoneCapture.startCapture() then enables voice processing and starts the engine.
// This ordering gives macOS AEC a complete I/O graph to reference.
let sharedEngine = AVAudioEngine()

// Memory layer — init is synchronous; CartesiaSpeaker attaches playerNode to sharedEngine here.
// Must complete before micCapture.start() calls engine.start().
let memoryEngine = MemoryEngine(context: context, audioRouter: audioRouter, engine: sharedEngine, logger: logger)
Task {
    let fi = await memoryEngine.faceIdentifier
    await router.setFaceIdentifier(fi)
    await memoryEngine.start()
}

// Start mic after MemoryEngine.init so playerNode is in the graph before engine.start().
let soundClassifier = SoundClassifier(context: context, logger: logger)
let micCapture = MicrophoneCapture(engine: sharedEngine, dispatcher: audioRouter, soundClassifier: soundClassifier, logger: logger)
micCapture.start()
```

- [ ] **Step 4: Build**

```bash
swift build
```

Expected: build succeeds with no errors — `main.swift` now compiles with the updated `MemoryEngine.init` signature and new `sharedEngine`. The `[warn] Voice processing (AEC) unavailable:` log should NOT appear on a normal macOS machine with an audio device.

- [ ] **Step 5: Run all tests**

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/BantiCore/MicrophoneCapture.swift Sources/banti/main.swift
git commit -m "feat: shared AVAudioEngine + setVoiceProcessingEnabled — hardware AEC replaces mute gate"
```

---

## Manual Integration Test

After all tasks complete, run banti and verify:

```bash
source .env && swift run banti
```

**Pass criteria (check each):**
- [ ] `microphone capture started (48000.0Hz → 16kHz)` appears in logs — engine started successfully
- [ ] No `[warn] Voice processing (AEC) unavailable` log — AEC enabled
- [ ] No `[error]` logs related to `AVAudioEngine`
- [ ] Speak naturally — Deepgram transcribes your voice → `[source: deepgram]` lines appear
- [ ] Let banti respond (TTS plays) — banti does NOT re-trigger on its own voice (no immediate second `[brain]` fire after playback)
- [ ] Speak while banti is talking — your voice is transcribed; banti's next response acknowledges the interruption
- [ ] Speak after banti finishes — normal behaviour, 10-second cooldown applies
