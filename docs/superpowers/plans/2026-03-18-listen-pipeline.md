# Listen Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add passive ambient audio monitoring — real-time speech transcription with speaker diarization (Deepgram), vocal emotion detection (Hume Speech Prosody), and on-device ambient sound classification (Apple SoundAnalysis).

**Architecture:** `MicrophoneCapture` taps `AVAudioEngine`, converts to 16kHz Int16 via `AVAudioConverter`, and feeds `AudioRouter`. The router streams every chunk to `DeepgramStreamer` (persistent WebSocket) and accumulates 3s buffers for `HumeVoiceAnalyzer` (connect-per-segment WebSocket). Native-rate `AVAudioPCMBuffer`s are passed directly to `SoundClassifier` (on-device `SNAudioStreamAnalyzer`) before downsampling. All results flow into `PerceptionContext` and surface in the existing 2s snapshot logger.

**Tech Stack:** AVAudioEngine, AVAudioConverter, URLSessionWebSocketTask (Deepgram + Hume), SoundAnalysis framework, Deepgram nova-2, Hume Expression Measurement API (prosody model)

**Spec:** `docs/superpowers/specs/2026-03-18-listen-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|----------------|
| `Sources/BantiCore/AudioTypes.swift` | `AudioChunkDispatcher` protocol, `AudioEvent` enum, `SpeechState`, `VoiceEmotionState`, `SoundState` |
| `Sources/BantiCore/HumeVoiceAnalyzer.swift` | WAV header construction, connect-per-segment WebSocket to Hume Speech Prosody |
| `Sources/BantiCore/DeepgramStreamer.swift` | Persistent WebSocket to Deepgram, PCM streaming, KeepAlive, auto-reconnect |
| `Sources/BantiCore/SoundClassifier.swift` | `SNAudioStreamAnalyzer` with monotonic frame position tracking |
| `Sources/BantiCore/AudioRouter.swift` | Actor; accumulates Hume buffer, dispatches to Deepgram + Hume, `configure()` |
| `Sources/BantiCore/MicrophoneCapture.swift` | `AVAudioEngine` tap, `AVAudioConverter` to 16kHz, dual-branch dispatch |
| `Tests/BantiTests/HumeVoiceAnalyzerTests.swift` | WAV header bytes, prosody response parsing |
| `Tests/BantiTests/DeepgramStreamerTests.swift` | JSON parsing fixtures, KeepAlive logic |
| `Tests/BantiTests/SoundClassifierTests.swift` | Frame position monotonicity |
| `Tests/BantiTests/AudioRouterTests.swift` | Buffer flush threshold, graceful degradation |

### Modified Files
| File | Change |
|------|--------|
| `Package.swift` | Add `SoundAnalysis` framework linkage to `BantiCore` target |
| `Sources/BantiCore/PerceptionTypes.swift` | +3 `PerceptionObservation` cases |
| `Sources/BantiCore/PerceptionContext.swift` | +3 state fields, `update()` switch arms, `snapshotJSON()` entries |
| `Sources/BantiCore/Logger.swift` | +4 color entries for audio sources |
| `Sources/banti/main.swift` | Wire `AudioRouter`, `SoundClassifier`, `MicrophoneCapture` |
| `Info.plist` | Update `NSMicrophoneUsageDescription` string |

---

## Task 1: Link SoundAnalysis framework in Package.swift

**Files:**
- Modify: `Package.swift`

`SoundAnalysis` is a system framework that requires explicit linkage in SPM. Without this step, Task 8 will fail with a linker error.

- [ ] **Step 1: Add linkerSettings to BantiCore target**

Open `Package.swift` and replace the `BantiCore` target with:
```swift
.target(
    name: "BantiCore",
    path: "Sources/BantiCore",
    linkerSettings: [
        .linkedFramework("SoundAnalysis")
    ]
),
```

- [ ] **Step 2: Build to confirm it still compiles**

```bash
swift build 2>&1 | grep "error:"
```
Expected: no errors

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "build: link SoundAnalysis framework for BantiCore"
```

---

## Task 3: AudioTypes.swift — protocols and state types

**Files:**
- Create: `Sources/BantiCore/AudioTypes.swift`

- [ ] **Step 1: Write a failing compile test**

Add to `Tests/BantiTests/BantiTests.swift`:
```swift
import BantiCore

// Compile-time check: AudioChunkDispatcher and state types exist
private func _audioTypesExist() {
    let _: SpeechState = SpeechState(transcript: "", speakerID: nil, isFinal: false, confidence: 0, updatedAt: Date())
    let _: VoiceEmotionState = VoiceEmotionState(emotions: [], updatedAt: Date())
    let _: SoundState = SoundState(label: "", confidence: 0, updatedAt: Date())
}
```

- [ ] **Step 2: Run to confirm it fails**

```bash
swift build 2>&1 | grep "error:"
```
Expected: `error: cannot find type 'SpeechState'`

- [ ] **Step 3: Create AudioTypes.swift**

```swift
// Sources/BantiCore/AudioTypes.swift
import Foundation

// MARK: - Dispatcher protocol (MicrophoneCapture depends on this, not the concrete actor)
// Sendable required: AVAudioEngine tap calls dispatch() from an audio thread outside any actor.
public protocol AudioChunkDispatcher: AnyObject, Sendable {
    func dispatch(pcmChunk: Data) async   // 16kHz mono Int16 linear16
}

// MARK: - Events (internal to AudioRouter)

public enum AudioEvent {
    case speechTranscribed(text: String, speakerID: Int?, isFinal: Bool, confidence: Float)
    case voiceEmotionDetected(emotions: [(label: String, score: Float)])
    case soundClassified(label: String, confidence: Float)
    case silence
}

// MARK: - State types (all Codable — required for PerceptionContext.snapshotJSON())

public struct SpeechState: Codable {
    public let transcript: String
    public let speakerID: Int?
    public let isFinal: Bool
    public let confidence: Float
    public let updatedAt: Date

    public init(transcript: String, speakerID: Int?, isFinal: Bool, confidence: Float, updatedAt: Date) {
        self.transcript = transcript
        self.speakerID = speakerID
        self.isFinal = isFinal
        self.confidence = confidence
        self.updatedAt = updatedAt
    }
}

public struct VoiceEmotionState: Codable {
    public struct Emotion: Codable {
        public let label: String
        public let score: Float
        public init(label: String, score: Float) { self.label = label; self.score = score }
    }
    public let emotions: [Emotion]
    public let updatedAt: Date

    public init(emotions: [(label: String, score: Float)], updatedAt: Date) {
        self.emotions = emotions.map { Emotion(label: $0.label, score: $0.score) }
        self.updatedAt = updatedAt
    }
}

public struct SoundState: Codable {
    public let label: String
    public let confidence: Float
    public let updatedAt: Date

    public init(label: String, confidence: Float, updatedAt: Date) {
        self.label = label
        self.confidence = confidence
        self.updatedAt = updatedAt
    }
}
```

- [ ] **Step 4: Run to confirm it compiles**

```bash
swift build 2>&1 | grep "error:"
```
Expected: no errors

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/AudioTypes.swift Tests/BantiTests/BantiTests.swift
git commit -m "feat: add AudioTypes — AudioChunkDispatcher protocol and audio state types"
```

---

## Task 4: Extend PerceptionTypes with audio observation cases

**Files:**
- Modify: `Sources/BantiCore/PerceptionTypes.swift`
- Test: `Tests/BantiTests/PerceptionTypesTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `Tests/BantiTests/PerceptionTypesTests.swift`:
```swift
func testSpeechObservationCase() {
    let state = SpeechState(transcript: "hello", speakerID: 0, isFinal: true, confidence: 0.99, updatedAt: Date())
    let obs = PerceptionObservation.speech(state)
    if case .speech(let s) = obs {
        XCTAssertEqual(s.transcript, "hello")
    } else {
        XCTFail("Expected .speech case")
    }
}

func testVoiceEmotionObservationCase() {
    let state = VoiceEmotionState(emotions: [("Joy", 0.9)], updatedAt: Date())
    let obs = PerceptionObservation.voiceEmotion(state)
    if case .voiceEmotion(let s) = obs {
        XCTAssertEqual(s.emotions.first?.label, "Joy")
    } else {
        XCTFail("Expected .voiceEmotion case")
    }
}

func testSoundObservationCase() {
    let state = SoundState(label: "dog_bark", confidence: 0.85, updatedAt: Date())
    let obs = PerceptionObservation.sound(state)
    if case .sound(let s) = obs {
        XCTAssertEqual(s.label, "dog_bark")
    } else {
        XCTFail("Expected .sound case")
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
swift test --filter PerceptionTypesTests 2>&1 | grep "error:"
```
Expected: `error: type 'PerceptionObservation' has no member 'speech'`

- [ ] **Step 3: Add cases to PerceptionObservation in PerceptionTypes.swift**

Append after the existing `case screen(ScreenState)` line:
```swift
case speech(SpeechState)
case voiceEmotion(VoiceEmotionState)
case sound(SoundState)
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter PerceptionTypesTests 2>&1 | tail -5
```
Expected: `Test Suite 'PerceptionTypesTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/PerceptionTypes.swift Tests/BantiTests/PerceptionTypesTests.swift
git commit -m "feat: extend PerceptionObservation with speech, voiceEmotion, sound cases"
```

---

## Task 5: Extend PerceptionContext with audio state fields

**Files:**
- Modify: `Sources/BantiCore/PerceptionContext.swift`
- Test: `Tests/BantiTests/PerceptionContextTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `Tests/BantiTests/PerceptionContextTests.swift`:
```swift
func testUpdateSetsSpeechField() async {
    let ctx = PerceptionContext()
    let state = SpeechState(transcript: "hi there", speakerID: 1, isFinal: true, confidence: 0.95, updatedAt: Date())
    await ctx.update(.speech(state))
    let speech = await ctx.speech
    XCTAssertEqual(speech?.transcript, "hi there")
    XCTAssertEqual(speech?.speakerID, 1)
}

func testUpdateSetsVoiceEmotionField() async {
    let ctx = PerceptionContext()
    let state = VoiceEmotionState(emotions: [("Calm", 0.7)], updatedAt: Date())
    await ctx.update(.voiceEmotion(state))
    let ve = await ctx.voiceEmotion
    XCTAssertEqual(ve?.emotions.first?.label, "Calm")
}

func testUpdateSetsSoundField() async {
    let ctx = PerceptionContext()
    let state = SoundState(label: "music", confidence: 0.88, updatedAt: Date())
    await ctx.update(.sound(state))
    let sound = await ctx.sound
    XCTAssertEqual(sound?.label, "music")
}

func testSnapshotIncludesAudioFields() async {
    let ctx = PerceptionContext()
    await ctx.update(.speech(SpeechState(transcript: "testing", speakerID: nil, isFinal: true, confidence: 0.9, updatedAt: Date())))
    await ctx.update(.sound(SoundState(label: "speech", confidence: 0.95, updatedAt: Date())))
    let json = await ctx.snapshotJSON()
    XCTAssertTrue(json.contains("testing"))
    XCTAssertTrue(json.contains("speech"))
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
swift test --filter PerceptionContextTests 2>&1 | grep "error:"
```
Expected: `error: value of type 'PerceptionContext' has no member 'speech'`

- [ ] **Step 3: Update PerceptionContext.swift**

Add three fields after `public var activity: ActivityState?`:
```swift
public var speech:        SpeechState?
public var voiceEmotion:  VoiceEmotionState?
public var sound:         SoundState?
```

Add three switch arms to `update()` after `case .screen(let s): screen = s`:
```swift
case .speech(let s):       speech = s
case .voiceEmotion(let s): voiceEmotion = s
case .sound(let s):        sound = s
```

Add three entries to `snapshotJSON()` after `if let a = activity`:
```swift
if let s = speech       { dict["speech"]       = encodable(s) }
if let v = voiceEmotion { dict["voiceEmotion"]  = encodable(v) }
if let s = sound        { dict["sound"]         = encodable(s) }
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter PerceptionContextTests 2>&1 | tail -5
```
Expected: `Test Suite 'PerceptionContextTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/PerceptionContext.swift Tests/BantiTests/PerceptionContextTests.swift
git commit -m "feat: extend PerceptionContext with speech, voiceEmotion, sound state fields"
```

---

## Task 6: Add audio log colors to Logger

**Files:**
- Modify: `Sources/BantiCore/Logger.swift`
- Test: `Tests/BantiTests/LoggerTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `Tests/BantiTests/LoggerTests.swift`:
```swift
func testDeepgramSourceLogsWithoutCrash() {
    var output = ""
    let logger = Logger { output = $0 }
    logger.log(source: "deepgram", message: "transcript received")
    // Give async queue a moment
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertTrue(output.contains("deepgram"))
    XCTAssertTrue(output.contains("transcript received"))
}

func testHumeVoiceSourceLogs() {
    var output = ""
    let logger = Logger { output = $0 }
    logger.log(source: "hume-voice", message: "prosody result")
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertTrue(output.contains("hume-voice"))
}
```

- [ ] **Step 2: Run to confirm they pass (or note current behavior)**

```bash
swift test --filter LoggerTests 2>&1 | tail -5
```
These tests should actually pass already (Logger's default case is white). Run them now to establish baseline.

- [ ] **Step 3: Add color entries to Logger.colorize()**

Add four cases before `default: color = ANSI.white`:
```swift
case "deepgram":    color = ANSI.cyan
case "hume-voice":  color = ANSI.magenta
case "sound":       color = ANSI.yellow
case "audio":       color = ANSI.white
```

- [ ] **Step 4: Run tests to confirm they still pass**

```bash
swift test --filter LoggerTests 2>&1 | tail -5
```
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/Logger.swift Tests/BantiTests/LoggerTests.swift
git commit -m "feat: add ANSI color entries for deepgram, hume-voice, sound, audio log sources"
```

---

## Task 7: Update Info.plist microphone description

**Files:**
- Modify: `Info.plist`

- [ ] **Step 1: Update the NSMicrophoneUsageDescription string**

Open `Info.plist` and change:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Banti will use the microphone in a future version.</string>
```
to:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Banti uses the microphone to listen, transcribe speech, and understand the room.</string>
```

- [ ] **Step 2: Verify the change**

```bash
grep -A1 "NSMicrophoneUsageDescription" Info.plist
```
Expected: `<string>Banti uses the microphone to listen, transcribe speech, and understand the room.</string>`

- [ ] **Step 3: Commit**

```bash
git add Info.plist
git commit -m "chore: update NSMicrophoneUsageDescription for live microphone use"
```

---

## Task 8: HumeVoiceAnalyzer — WAV header + WebSocket + response parsing

**Files:**
- Create: `Sources/BantiCore/HumeVoiceAnalyzer.swift`
- Create: `Tests/BantiTests/HumeVoiceAnalyzerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/BantiTests/HumeVoiceAnalyzerTests.swift`:
```swift
// Tests/BantiTests/HumeVoiceAnalyzerTests.swift
import XCTest
@testable import BantiCore

final class HumeVoiceAnalyzerTests: XCTestCase {

    // MARK: WAV header

    func testWAVHeaderByteLayout() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = HumeVoiceAnalyzer.makeWAV(pcmData: pcm)
        XCTAssertEqual(wav.count, 144)  // 44-byte header + 100 bytes data
        // "RIFF"
        XCTAssertEqual(wav[0..<4], "RIFF".data(using: .utf8)!)
        // Total size = 100 + 36 = 136, little-endian
        XCTAssertEqual(wav[4..<8], Data([136, 0, 0, 0]))
        // "WAVE"
        XCTAssertEqual(wav[8..<12], "WAVE".data(using: .utf8)!)
        // "fmt "
        XCTAssertEqual(wav[12..<16], "fmt ".data(using: .utf8)!)
        // fmt chunk size = 16
        XCTAssertEqual(wav[16..<20], Data([16, 0, 0, 0]))
        // Audio format = 1 (PCM)
        XCTAssertEqual(wav[20..<22], Data([1, 0]))
        // Channels = 1
        XCTAssertEqual(wav[22..<24], Data([1, 0]))
        // Sample rate = 16000 = 0x3E80, LE = [0x80, 0x3E, 0x00, 0x00]
        XCTAssertEqual(wav[24..<28], Data([0x80, 0x3E, 0x00, 0x00]))
        // Byte rate = 32000 = 0x7D00, LE = [0x00, 0x7D, 0x00, 0x00]
        XCTAssertEqual(wav[28..<32], Data([0x00, 0x7D, 0x00, 0x00]))
        // Block align = 2
        XCTAssertEqual(wav[32..<34], Data([2, 0]))
        // Bits per sample = 16
        XCTAssertEqual(wav[34..<36], Data([16, 0]))
        // "data"
        XCTAssertEqual(wav[36..<40], "data".data(using: .utf8)!)
        // Data chunk size = 100, LE
        XCTAssertEqual(wav[40..<44], Data([100, 0, 0, 0]))
    }

    func testWAVPayloadIsAppended() {
        let pcm = Data([0x01, 0x02, 0x03])
        let wav = HumeVoiceAnalyzer.makeWAV(pcmData: pcm)
        XCTAssertEqual(wav.suffix(3), Data([0x01, 0x02, 0x03]))
    }

    // MARK: Response parsing

    func testParseResponseExtractsProsodyEmotions() {
        let json = """
        {
          "prosody": {
            "predictions": [{
              "emotions": [
                { "name": "Joy", "score": 0.87 },
                { "name": "Calm", "score": 0.45 }
              ]
            }]
          }
        }
        """
        let state = HumeVoiceAnalyzer.parseResponse(json.data(using: .utf8)!)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.emotions.count, 2)
        XCTAssertEqual(state?.emotions.first?.label, "Joy")
        XCTAssertEqual(state?.emotions.first?.score ?? 0, 0.87, accuracy: 0.001)
    }

    func testParseResponseReturnsNilForMissingProsody() {
        let json = """{ "face": {} }"""
        let state = HumeVoiceAnalyzer.parseResponse(json.data(using: .utf8)!)
        XCTAssertNil(state)
    }

    func testParseResponseReturnsNilForEmptyPredictions() {
        let json = """{ "prosody": { "predictions": [] } }"""
        let state = HumeVoiceAnalyzer.parseResponse(json.data(using: .utf8)!)
        XCTAssertNil(state)
    }

    func testAnalyzeReturnsNilForEmptyPCM() async {
        let analyzer = HumeVoiceAnalyzer(apiKey: "test", context: PerceptionContext(), logger: Logger())
        let result = await analyzer.analyze(pcmData: Data())
        XCTAssertNil(result)
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
swift test --filter HumeVoiceAnalyzerTests 2>&1 | grep "error:"
```
Expected: `error: cannot find 'HumeVoiceAnalyzer' in scope`

- [ ] **Step 3: Create HumeVoiceAnalyzer.swift**

```swift
// Sources/BantiCore/HumeVoiceAnalyzer.swift
import Foundation

public final class HumeVoiceAnalyzer {
    private let apiKey: String
    private let context: PerceptionContext
    private let logger: Logger
    private let session: URLSession

    public init(apiKey: String, context: PerceptionContext, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.context = context
        self.logger = logger
        self.session = session
    }

    /// Analyze a PCM segment: wrap in WAV, send to Hume, update PerceptionContext.
    /// Returns nil (and skips context update) if pcmData is empty or the API call fails.
    public func analyze(pcmData: Data) async -> VoiceEmotionState? {
        guard !pcmData.isEmpty else { return nil }
        let wavData = HumeVoiceAnalyzer.makeWAV(pcmData: pcmData)
        return await callHumeAPI(wavData: wavData)
    }

    // MARK: - WAV header construction (internal for testability)

    /// Wraps raw PCM bytes in a 44-byte RIFF/WAV header.
    /// Parameters default to 16kHz mono Int16 — the format produced by MicrophoneCapture.
    static func makeWAV(pcmData: Data,
                        sampleRate: UInt32 = 16_000,
                        channels: UInt16 = 1,
                        bitsPerSample: UInt16 = 16) -> Data {
        let dataSize   = UInt32(pcmData.count)
        let byteRate   = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var header = Data(capacity: 44)
        header.append(contentsOf: "RIFF".utf8)
        header.appendLE(dataSize + 36)      // total size − 8
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendLE(UInt32(16))         // PCM subchunk size
        header.appendLE(UInt16(1))          // PCM audio format
        header.appendLE(channels)
        header.appendLE(sampleRate)
        header.appendLE(byteRate)
        header.appendLE(blockAlign)
        header.appendLE(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendLE(dataSize)
        return header + pcmData
    }

    // MARK: - Response parsing (internal for testability)

    static func parseResponse(_ data: Data) -> VoiceEmotionState? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prosody = json["prosody"] as? [String: Any],
              let predictions = prosody["predictions"] as? [[String: Any]],
              let first = predictions.first,
              let emotions = first["emotions"] as? [[String: Any]],
              !emotions.isEmpty else { return nil }

        let parsed = emotions.compactMap { e -> (label: String, score: Float)? in
            guard let name = e["name"] as? String,
                  let score = e["score"] as? Double else { return nil }
            return (label: name, score: Float(score))
        }
        guard !parsed.isEmpty else { return nil }
        return VoiceEmotionState(emotions: parsed, updatedAt: Date())
    }

    // MARK: - API call

    private func callHumeAPI(wavData: Data) async -> VoiceEmotionState? {
        guard let url = URL(string: "wss://api.hume.ai/v0/stream/models?api_key=\(apiKey)") else { return nil }

        let body: [String: Any] = [
            "models": ["prosody": [:]],
            "data":   wavData.base64EncodedString()
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let bodyString = String(data: bodyData, encoding: .utf8) else { return nil }

        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        do {
            try await task.send(.string(bodyString))
            let message = try await withTimeout(seconds: 10) {
                try await task.receive()
            }
            switch message {
            case .string(let text): return HumeVoiceAnalyzer.parseResponse(text.data(using: .utf8) ?? Data())
            case .data(let data):   return HumeVoiceAnalyzer.parseResponse(data)
            @unknown default:       return nil
            }
        } catch {
            logger.log(source: "hume-voice", message: "[warn] \(error.localizedDescription)")
            return nil
        }
    }

    private func withTimeout<T: Sendable>(seconds: Double,
                                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Data helpers for little-endian encoding

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter HumeVoiceAnalyzerTests 2>&1 | tail -5
```
Expected: `Test Suite 'HumeVoiceAnalyzerTests' passed`

Note: `testAnalyzeReturnsNilForEmptyPCM` passes without a network call (early return on empty data).

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/HumeVoiceAnalyzer.swift Tests/BantiTests/HumeVoiceAnalyzerTests.swift
git commit -m "feat: add HumeVoiceAnalyzer — WAV header construction and Hume Speech Prosody WebSocket"
```

---

## Task 9: DeepgramStreamer — WebSocket streaming + reconnect + KeepAlive + parsing

**Files:**
- Create: `Sources/BantiCore/DeepgramStreamer.swift`
- Create: `Tests/BantiTests/DeepgramStreamerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/BantiTests/DeepgramStreamerTests.swift`:
```swift
// Tests/BantiTests/DeepgramStreamerTests.swift
import XCTest
@testable import BantiCore

final class DeepgramStreamerTests: XCTestCase {

    // MARK: JSON parsing

    func testParseResponseExtractsTranscriptAndSpeaker() {
        let json = """
        {
          "channel": {
            "alternatives": [{
              "transcript": "hello world",
              "confidence": 0.99,
              "words": [{ "word": "hello", "speaker": 0 }]
            }]
          },
          "is_final": true
        }
        """
        let state = DeepgramStreamer.parseResponse(json.data(using: .utf8)!)
        XCTAssertEqual(state?.transcript, "hello world")
        XCTAssertEqual(state?.speakerID, 0)
        XCTAssertTrue(state?.isFinal ?? false)
        XCTAssertEqual(state?.confidence ?? 0, 0.99, accuracy: 0.001)
    }

    func testParseResponseReturnsNilForNonFinal() {
        let json = """
        {
          "channel": { "alternatives": [{ "transcript": "hel", "confidence": 0.5, "words": [] }] },
          "is_final": false
        }
        """
        let state = DeepgramStreamer.parseResponse(json.data(using: .utf8)!)
        XCTAssertNil(state)
    }

    func testParseResponseHandlesMissingSpeaker() {
        let json = """
        {
          "channel": { "alternatives": [{ "transcript": "solo", "confidence": 0.8, "words": [] }] },
          "is_final": true
        }
        """
        let state = DeepgramStreamer.parseResponse(json.data(using: .utf8)!)
        XCTAssertEqual(state?.transcript, "solo")
        XCTAssertNil(state?.speakerID)
    }

    func testParseResponseReturnsNilForMalformedJSON() {
        let state = DeepgramStreamer.parseResponse(Data("not json".utf8))
        XCTAssertNil(state)
    }

    // MARK: KeepAlive logic

    func testShouldSendKeepAliveAfter8Seconds() {
        let last = Date(timeIntervalSinceNow: -8.5)
        XCTAssertTrue(DeepgramStreamer.shouldSendKeepAlive(lastChunkAt: last, now: Date()))
    }

    func testShouldNotSendKeepAliveWithin8Seconds() {
        let last = Date(timeIntervalSinceNow: -3.0)
        XCTAssertFalse(DeepgramStreamer.shouldSendKeepAlive(lastChunkAt: last, now: Date()))
    }

    func testShouldSendKeepAliveAtExactlyThreshold() {
        let last = Date(timeIntervalSinceNow: -8.0)
        XCTAssertTrue(DeepgramStreamer.shouldSendKeepAlive(lastChunkAt: last, now: Date()))
    }

    // MARK: Reconnect buffer

    func testReconnectBufferMaxIs160000Bytes() {
        XCTAssertEqual(DeepgramStreamer.maxReconnectBufferBytes, 160_000)
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
swift test --filter DeepgramStreamerTests 2>&1 | grep "error:"
```
Expected: `error: cannot find 'DeepgramStreamer' in scope`

- [ ] **Step 3: Create DeepgramStreamer.swift**

```swift
// Sources/BantiCore/DeepgramStreamer.swift
import Foundation

public actor DeepgramStreamer {
    private let apiKey: String
    private let context: PerceptionContext
    private let logger: Logger
    private let session: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    private var reconnectDelay: Double = 1.0
    private static let maxReconnectDelay: Double = 30.0

    private var reconnectBuffer: Data = Data()
    static let maxReconnectBufferBytes = 160_000

    private var lastChunkAt: Date?
    private var isConnected = false

    public init(apiKey: String, context: PerceptionContext, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.context = context
        self.logger = logger
        self.session = session
    }

    // MARK: - Public API

    /// Send a PCM chunk to Deepgram. Connects on first call.
    public func send(chunk: Data) async {
        lastChunkAt = Date()

        if !isConnected {
            connect()
        }

        guard let task = webSocketTask, isConnected else {
            // Still reconnecting — buffer the chunk
            if reconnectBuffer.count + chunk.count <= DeepgramStreamer.maxReconnectBufferBytes {
                reconnectBuffer.append(chunk)
            }
            return
        }

        do {
            try await task.send(.data(chunk))
        } catch {
            logger.log(source: "deepgram", message: "[warn] send failed: \(error.localizedDescription)")
            handleDisconnect()
        }
    }

    // MARK: - KeepAlive (internal + static for testability)

    static func shouldSendKeepAlive(lastChunkAt: Date, now: Date = Date(), silenceThreshold: Double = 8.0) -> Bool {
        now.timeIntervalSince(lastChunkAt) >= silenceThreshold
    }

    // MARK: - Connection management

    private func connect() {
        guard !isConnected else { return }

        let urlString = "wss://api.deepgram.com/v1/listen?model=nova-2&diarize=true&punctuate=true&encoding=linear16&sample_rate=16000&channels=1"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        isConnected = true
        reconnectDelay = 1.0
        logger.log(source: "deepgram", message: "connected")

        startReceiveLoop()
        startKeepAliveMonitor()
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = await self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    await self.handleMessage(message)
                } catch {
                    await self.handleDisconnect()
                    break
                }
            }
        }
    }

    private func startKeepAliveMonitor() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { break }
                if let last = await self.lastChunkAt,
                   DeepgramStreamer.shouldSendKeepAlive(lastChunkAt: last) {
                    await self.sendKeepAlive()
                }
            }
        }
    }

    private func sendKeepAlive() {
        guard let task = webSocketTask, isConnected else { return }
        Task {
            do {
                try await task.send(.string(#"{"type":"KeepAlive"}"#))
            } catch {
                logger.log(source: "deepgram", message: "[warn] KeepAlive failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleDisconnect() {
        guard isConnected else { return }   // prevent double-reconnect from concurrent failures
        isConnected = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        receiveTask?.cancel()
        keepAliveTask?.cancel()

        // Discard reconnect buffer (no replay to avoid duplicate transcripts)
        reconnectBuffer = Data()

        logger.log(source: "deepgram", message: "[warn] disconnected, reconnecting in \(reconnectDelay)s")

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, DeepgramStreamer.maxReconnectDelay)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.connect()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let d):      data = d
        @unknown default:       data = nil
        }

        guard let data,
              let state = DeepgramStreamer.parseResponse(data) else { return }

        logger.log(source: "deepgram", message: "[\(state.speakerID.map { "spk:\($0)" } ?? "?")] \(state.transcript)")
        await context.update(.speech(state))
    }

    // MARK: - Response parsing (static + internal for testability)

    static func parseResponse(_ data: Data) -> SpeechState? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isFinal = json["is_final"] as? Bool, isFinal,
              let channel = json["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let first = alternatives.first,
              let transcript = first["transcript"] as? String,
              !transcript.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let confidence = (first["confidence"] as? Double).map { Float($0) } ?? 0.0
        let words = first["words"] as? [[String: Any]]
        let speakerID = words?.first.flatMap { $0["speaker"] as? Int }

        return SpeechState(
            transcript: transcript,
            speakerID: speakerID,
            isFinal: true,
            confidence: confidence,
            updatedAt: Date()
        )
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter DeepgramStreamerTests 2>&1 | tail -5
```
Expected: `Test Suite 'DeepgramStreamerTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/DeepgramStreamer.swift Tests/BantiTests/DeepgramStreamerTests.swift
git commit -m "feat: add DeepgramStreamer — streaming WebSocket with reconnect, KeepAlive, and transcript parsing"
```

---

## Task 10: SoundClassifier — SNAudioStreamAnalyzer + frame position tracking

**Files:**
- Create: `Sources/BantiCore/SoundClassifier.swift`
- Create: `Tests/BantiTests/SoundClassifierTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/BantiTests/SoundClassifierTests.swift`:
```swift
// Tests/BantiTests/SoundClassifierTests.swift
import XCTest
import AVFoundation
@testable import BantiCore

final class SoundClassifierTests: XCTestCase {

    func testFramePositionStartsAtZero() {
        let classifier = SoundClassifier(context: PerceptionContext(), logger: Logger())
        XCTAssertEqual(classifier.currentFramePosition, 0)
    }

    func testFramePositionIncrementsBy1024() {
        let classifier = SoundClassifier(context: PerceptionContext(), logger: Logger())
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44100, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            XCTFail("Could not create buffer"); return
        }
        buf.frameLength = 1024
        classifier.analyze(buffer: buf)
        XCTAssertEqual(classifier.currentFramePosition, 1024)
    }

    func testFramePositionIncrementsMonotonically() {
        let classifier = SoundClassifier(context: PerceptionContext(), logger: Logger())
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44100, channels: 1, interleaved: false)!

        for frameLength in [1024, 512, 2048] as [AVAudioFrameCount] {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
                XCTFail("Could not create buffer"); return
            }
            buf.frameLength = frameLength
            classifier.analyze(buffer: buf)
        }
        // Total = 1024 + 512 + 2048 = 3584
        XCTAssertEqual(classifier.currentFramePosition, 3584)
    }

    func testFramePositionNeverResets() {
        let classifier = SoundClassifier(context: PerceptionContext(), logger: Logger())
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44100, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else {
            XCTFail("Could not create buffer"); return
        }
        buf.frameLength = 512
        classifier.analyze(buffer: buf)
        classifier.analyze(buffer: buf)
        classifier.analyze(buffer: buf)
        // Must be 1536, not 512 (which would indicate a reset)
        XCTAssertEqual(classifier.currentFramePosition, 1536)
        XCTAssertGreaterThan(classifier.currentFramePosition, 512)
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
swift test --filter SoundClassifierTests 2>&1 | grep "error:"
```
Expected: `error: cannot find 'SoundClassifier' in scope`

- [ ] **Step 3: Create SoundClassifier.swift**

```swift
// Sources/BantiCore/SoundClassifier.swift
import Foundation
import AVFoundation
import SoundAnalysis

public final class SoundClassifier: NSObject {
    private let context: PerceptionContext
    private let logger: Logger
    private let analysisQueue = DispatchQueue(label: "banti.soundclassifier", qos: .userInitiated)
    private var analyzer: SNAudioStreamAnalyzer?
    private var lastEmittedAt: Date?
    private static let throttleSeconds: Double = 1.0
    private static let confidenceThreshold: Float = 0.7

    /// Frame position counter — incremented synchronously on each analyze() call.
    /// Exposed internally for testing.
    public private(set) var currentFramePosition: AVAudioFramePosition = 0

    public init(context: PerceptionContext, logger: Logger) {
        self.context = context
        self.logger = logger
        super.init()
    }

    /// Call this once with the hardware audio format from AVAudioEngine's inputNode.
    /// Must be called before analyze(buffer:).
    public func setup(inputFormat: AVAudioFormat) {
        let streamAnalyzer = SNAudioStreamAnalyzer(format: inputFormat)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try streamAnalyzer.add(request, withObserver: self)
            analyzer = streamAnalyzer
        } catch {
            logger.log(source: "sound", message: "[warn] SoundAnalysis setup failed: \(error.localizedDescription)")
        }
    }

    /// Called from MicrophoneCapture's audio tap with native-rate buffers.
    /// Frame position is incremented synchronously; analysis is queued asynchronously.
    public func analyze(buffer: AVAudioPCMBuffer) {
        let pos = currentFramePosition
        currentFramePosition += AVAudioFramePosition(buffer.frameLength)
        analysisQueue.async { [weak self] in
            self?.analyzer?.analyze(buffer, atAudioFramePosition: pos)
        }
    }
}

// MARK: - SNResultsObserving

extension SoundClassifier: SNResultsObserving {
    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let top = result.classifications.first,
              Float(top.confidence) > SoundClassifier.confidenceThreshold else { return }

        let now = Date()
        if let last = lastEmittedAt, now.timeIntervalSince(last) < SoundClassifier.throttleSeconds { return }
        lastEmittedAt = now

        let state = SoundState(label: top.identifier, confidence: Float(top.confidence), updatedAt: now)
        logger.log(source: "sound", message: "\(top.identifier) (\(String(format: "%.2f", top.confidence)))")
        Task { await context.update(.sound(state)) }
    }

    public func request(_ request: SNRequest, didFailWithError error: Error) {
        logger.log(source: "sound", message: "[warn] analysis error: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter SoundClassifierTests 2>&1 | tail -5
```
Expected: `Test Suite 'SoundClassifierTests' passed`

Note: Tests only verify frame position logic. The actual `SNAudioStreamAnalyzer.analyze` call runs async and is not asserted in unit tests (requires real audio input for meaningful results).

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/SoundClassifier.swift Tests/BantiTests/SoundClassifierTests.swift
git commit -m "feat: add SoundClassifier — SNAudioStreamAnalyzer with monotonic frame position tracking"
```

---

## Task 11: AudioRouter — buffer accumulation + configure + graceful degradation

**Files:**
- Create: `Sources/BantiCore/AudioRouter.swift`
- Create: `Tests/BantiTests/AudioRouterTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/BantiTests/AudioRouterTests.swift`:
```swift
// Tests/BantiTests/AudioRouterTests.swift
import XCTest
@testable import BantiCore

final class AudioRouterTests: XCTestCase {

    // MARK: Buffer accumulation

    func testHumeFlushThresholdIs96000Bytes() {
        XCTAssertEqual(AudioRouter.humeFlushThreshold, 96_000)
    }

    func testBufferAccumulatesBeforeThreshold() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 1_000)
        // Send 95 chunks = 95,000 bytes (below 96,000 threshold)
        for _ in 0..<95 { await router.dispatch(pcmChunk: chunk) }
        let count = await router.humeBufferCount
        XCTAssertEqual(count, 95_000)
    }

    func testBufferResetsAfterThreshold() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 1_000)
        // 96 chunks = 96,000 bytes → triggers flush → buffer resets to 0
        for _ in 0..<96 { await router.dispatch(pcmChunk: chunk) }
        let count = await router.humeBufferCount
        XCTAssertEqual(count, 0)
    }

    func testBufferContinuesAccumulatingAfterFlush() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 1_000)
        // Fill past threshold (flush), then send 5 more
        for _ in 0..<101 { await router.dispatch(pcmChunk: chunk) }
        let count = await router.humeBufferCount
        XCTAssertEqual(count, 5_000)  // 101 * 1000 - 96000 = 5000
    }

    func testBufferResetsAtThresholdEvenWithoutHumeKey() async {
        // No configureWith call → hume is nil
        // Buffer must still reset to prevent unbounded memory growth
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 1_000)
        for _ in 0..<96 { await router.dispatch(pcmChunk: chunk) }
        let count = await router.humeBufferCount
        XCTAssertEqual(count, 0, "Buffer must reset at threshold even when hume analyzer is nil")
    }

    // MARK: Graceful degradation

    func testConfigureWithNilKeysDisablesBothAnalyzers() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        await router.configureWith(deepgramKey: nil, humeKey: nil)
        let hasDeepgram = await router.hasDeepgram
        let hasHume = await router.hasHume
        XCTAssertFalse(hasDeepgram)
        XCTAssertFalse(hasHume)
    }

    func testConfigureWithDeepgramKeyEnablesDeepgram() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        await router.configureWith(deepgramKey: "dg-test-key", humeKey: nil)
        let hasDeepgram = await router.hasDeepgram
        let hasHume = await router.hasHume
        XCTAssertTrue(hasDeepgram)
        XCTAssertFalse(hasHume)
    }

    func testConfigureWithBothKeysEnablesBothAnalyzers() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        await router.configureWith(deepgramKey: "dg-key", humeKey: "hume-key")
        XCTAssertTrue(await router.hasDeepgram)
        XCTAssertTrue(await router.hasHume)
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
swift test --filter AudioRouterTests 2>&1 | grep "error:"
```
Expected: `error: cannot find 'AudioRouter' in scope`

- [ ] **Step 3: Create AudioRouter.swift**

```swift
// Sources/BantiCore/AudioRouter.swift
import Foundation

public actor AudioRouter: AudioChunkDispatcher {
    private let context: PerceptionContext
    private let logger: Logger

    private var deepgram: DeepgramStreamer?
    private var hume: HumeVoiceAnalyzer?
    private var humeBuffer: Data = Data()

    /// 3 seconds at 16kHz × 1 channel × 2 bytes/sample = 96,000 bytes.
    static let humeFlushThreshold = 96_000

    public init(context: PerceptionContext, logger: Logger) {
        self.context = context
        self.logger = logger
    }

    // MARK: - Configuration

    /// Read API keys from environment and enable analyzers.
    /// Call from main.swift via Task { await router.configure() }.
    public func configure() {
        let env = ProcessInfo.processInfo.environment
        configureWith(
            deepgramKey: env["DEEPGRAM_API_KEY"],
            humeKey: env["HUME_API_KEY"]
        )
    }

    /// Testable configure with injected keys.
    public func configureWith(deepgramKey: String?, humeKey: String?) {
        if let key = deepgramKey {
            deepgram = DeepgramStreamer(apiKey: key, context: context, logger: logger)
        } else {
            logger.log(source: "audio", message: "[warn] DEEPGRAM_API_KEY missing — speech transcription disabled")
        }
        if let key = humeKey {
            hume = HumeVoiceAnalyzer(apiKey: key, context: context, logger: logger)
        } else {
            logger.log(source: "audio", message: "[warn] HUME_API_KEY missing — vocal emotion disabled")
        }
    }

    // MARK: - Dispatch (AudioChunkDispatcher)

    public func dispatch(pcmChunk: Data) async {
        // Stream every chunk to Deepgram
        if let streamer = deepgram {
            Task { await streamer.send(chunk: pcmChunk) }
        }

        // Accumulate for Hume; always reset at threshold to avoid unbounded growth
        // when HUME_API_KEY is absent and hume == nil.
        humeBuffer.append(pcmChunk)
        if humeBuffer.count >= AudioRouter.humeFlushThreshold {
            if let analyzer = hume {
                let segment = humeBuffer
                Task {
                    if let state = await analyzer.analyze(pcmData: segment) {
                        await self.context.update(.voiceEmotion(state))
                    }
                }
            }
            humeBuffer = Data()   // always reset, even when hume is nil
        }
    }

    // MARK: - Testable accessors

    var humeBufferCount: Int { humeBuffer.count }
    var hasDeepgram: Bool { deepgram != nil }
    var hasHume: Bool { hume != nil }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter AudioRouterTests 2>&1 | tail -5
```
Expected: `Test Suite 'AudioRouterTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/AudioRouter.swift Tests/BantiTests/AudioRouterTests.swift
git commit -m "feat: add AudioRouter — 3s Hume buffer accumulation, Deepgram streaming dispatch, graceful degradation"
```

---

## Task 12: MicrophoneCapture — AVAudioEngine tap + AVAudioConverter + dual dispatch

**Files:**
- Create: `Sources/BantiCore/MicrophoneCapture.swift`

No meaningful unit tests for `MicrophoneCapture` — `AVAudioEngine` is a concrete class that requires real hardware. The permission-denied path is verified manually. This task has no test file.

- [ ] **Step 1: Create MicrophoneCapture.swift**

```swift
// Sources/BantiCore/MicrophoneCapture.swift
import Foundation
import AVFoundation

public final class MicrophoneCapture {
    private let dispatcher: any AudioChunkDispatcher
    private let soundClassifier: SoundClassifier
    private let logger: Logger

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    public init(dispatcher: any AudioChunkDispatcher, soundClassifier: SoundClassifier, logger: Logger) {
        self.dispatcher = dispatcher
        self.soundClassifier = soundClassifier
        self.logger = logger
    }

    public func start() {
        requestPermissionAndStart()
    }

    public func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Private

    private func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted { self?.startCapture() }
                else { self?.permissionDenied() }
            }
        case .denied, .restricted:
            permissionDenied()
        @unknown default:
            break
        }
    }

    private func permissionDenied() {
        logger.log(source: "audio", message: "[error] Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone.")
        exit(1)
    }

    private func startCapture() {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Set up AVAudioConverter: hardware format → 16kHz mono Int16
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            logger.log(source: "audio", message: "[error] Failed to create AVAudioConverter from \(inputFormat) to 16kHz Int16")
            return
        }
        converter = conv

        // Set up SoundClassifier with the native hardware format (must happen before analyze calls)
        soundClassifier.setup(inputFormat: inputFormat)

        // Tap size: ~20ms at hardware rate
        let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.02)

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }

        do {
            try engine.start()
            logger.log(source: "audio", message: "microphone capture started (\(inputFormat.sampleRate)Hz → 16kHz)")
        } catch {
            logger.log(source: "audio", message: "[error] AVAudioEngine start failed: \(error.localizedDescription)")
        }
    }

    private func processTap(buffer: AVAudioPCMBuffer) {
        // Branch 1: SoundClassifier gets the native-rate buffer (before downsampling)
        soundClassifier.analyze(buffer: buffer)

        // Branch 2: Convert to 16kHz Int16 and dispatch to AudioRouter
        guard let conv = converter else { return }

        let inputFrameCount = buffer.frameLength
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(inputFrameCount) * targetFormat.sampleRate / buffer.format.sampleRate)
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }

        var error: NSError?
        var inputConsumed = false
        let status = conv.convert(to: outputBuffer, error: &error) { packetCount, statusPtr in
            if inputConsumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            statusPtr.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, outputBuffer.frameLength > 0 else { return }

        // Package Int16 frames as Data and dispatch
        let byteCount = Int(outputBuffer.frameLength) * 2  // 2 bytes per Int16 frame
        guard let int16Ptr = outputBuffer.int16ChannelData?[0] else { return }
        let chunk = Data(bytes: int16Ptr, count: byteCount)

        // AVAudioEngine tap is synchronous; use Task to call the async dispatcher
        Task { await dispatcher.dispatch(pcmChunk: chunk) }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
swift build 2>&1 | grep "error:"
```
Expected: no errors

- [ ] **Step 3: Commit**

```bash
git add Sources/BantiCore/MicrophoneCapture.swift
git commit -m "feat: add MicrophoneCapture — AVAudioEngine tap with AVAudioConverter to 16kHz and dual-branch dispatch"
```

---

## Task 13: Wire audio pipeline into main.swift

**Files:**
- Modify: `Sources/banti/main.swift`

- [ ] **Step 1: Add audio components to main.swift**

Open `Sources/banti/main.swift` and add after the existing `axReader.start()` section:

```swift
// Audio pipeline
let audioRouter = AudioRouter(context: context, logger: logger)
Task { await audioRouter.configure() }

let soundClassifier = SoundClassifier(context: context, logger: logger)
let micCapture = MicrophoneCapture(dispatcher: audioRouter, soundClassifier: soundClassifier, logger: logger)
micCapture.start()
```

The final `main.swift` should look like:

```swift
// Sources/banti/main.swift
import Foundation
import AppKit
import BantiCore

// Shared infrastructure
let logger = Logger()

logger.log(source: "system", message: "banti starting...")

// Perception pipeline
let context = PerceptionContext()
let router  = PerceptionRouter(context: context, logger: logger)

// Configure cloud analyzers from environment variables
Task { await router.configure() }

let localPerception = LocalPerception(dispatcher: router)

// Start snapshot logging (every 2s)
context.startSnapshotTimer(logger: logger)

// Start AX reader (accessibility side-channel)
let axReader = AXReader(logger: logger)
axReader.start()

// Start camera capture
let deduplicator = Deduplicator()
let cameraCapture = CameraCapture(logger: logger, deduplicator: deduplicator, frameProcessor: localPerception)
cameraCapture.start()

// Start screen capture (async)
let screenDeduplicator = Deduplicator()
let screenCapture = ScreenCapture(logger: logger, deduplicator: screenDeduplicator, frameProcessor: localPerception)
Task {
    await screenCapture.start()
}

// Audio pipeline
let audioRouter = AudioRouter(context: context, logger: logger)
Task { await audioRouter.configure() }

let soundClassifier = SoundClassifier(context: context, logger: logger)
let micCapture = MicrophoneCapture(dispatcher: audioRouter, soundClassifier: soundClassifier, logger: logger)
micCapture.start()

logger.log(source: "system", message: "banti running. Press Ctrl+C to stop.")
RunLoop.main.run()
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
swift build 2>&1 | grep "error:"
```
Expected: no errors (may see warnings about unused variables — those are fine)

- [ ] **Step 3: Run all tests**

```bash
swift test 2>&1 | tail -10
```
Expected: all test suites pass

- [ ] **Step 4: Commit**

```bash
git add Sources/banti/main.swift
git commit -m "feat: wire listen pipeline — AudioRouter, SoundClassifier, MicrophoneCapture into main.swift"
```

---

## Verification Checklist

After all tasks are complete, verify the full pipeline manually:

1. Set environment variables:
   ```bash
   export DEEPGRAM_API_KEY="your-key"
   export HUME_API_KEY="your-key"
   ```
2. Build and run:
   ```bash
   swift run
   ```
3. Confirm in log output:
   - `[source: audio]` microphone capture started with hardware sample rate
   - `[source: deepgram]` connected
   - Speaking aloud should produce `[source: deepgram]` transcript lines within ~1-2s
   - After ~3s of speaking, `[source: perception]` snapshot should include `"speech"` and `"voiceEmotion"` keys
   - Ambient sounds at confidence > 0.7 should appear as `[source: sound]` lines
