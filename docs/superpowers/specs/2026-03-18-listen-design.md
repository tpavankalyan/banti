# Listen Pipeline Design

**Date:** 2026-03-18
**Status:** Approved

## Goal

Add passive ambient audio monitoring to banti. Banti should continuously listen to the room, transcribe speech in near real-time with speaker diarization, detect vocal emotion, and classify ambient sounds.

## Requirements

| Capability | Priority |
|---|---|
| Speech transcription (near real-time, < 1-2s lag) | Must have |
| Speaker diarization (who is speaking) | Must have |
| Vocal emotion detection (how it is spoken) | Must have |
| Ambient sound classification | Nice to have |

## Architecture

The listen pipeline mirrors the existing see pipeline: a capture layer feeds a router which dispatches to analyzers that update `PerceptionContext`.

```
AVAudioEngine (hardware rate, e.g. 44.1kHz or 48kHz)
    ↓  tap on inputNode (native format)
    ├── SoundClassifier branch: AVAudioPCMBuffer at native rate → SNAudioStreamAnalyzer
    └── 16kHz branch: AVAudioConverter → 16kHz mono Int16 PCM chunks
                          ↓
                    AudioRouter (actor)
                          ├── DeepgramStreamer  — persistent WebSocket, streams PCM
                          │                       → SpeechState
                          └── HumeVoiceAnalyzer — ~3s WAV chunks
                                                  → VoiceEmotionState

All three → PerceptionContext → snapshotted by existing 2s logger
```

**Key constraint:** `SNAudioStreamAnalyzer` (SoundAnalysis framework) requires `AVAudioPCMBuffer` at the hardware's native sample rate — it cannot accept 16kHz resampled data. Therefore `SoundClassifier` taps the audio before downsampling.

## Technology Choices

| Concern | Technology | Reason |
|---|---|---|
| Transcription + diarization | Deepgram `nova-2` streaming WebSocket | Best real-time accuracy + built-in diarization. Use `nova-2` as default; `nova-3` has limited availability and should only be enabled if confirmed accessible. |
| Vocal emotion | Hume Speech Prosody API | Already integrated for face emotion; top prosody model |
| Ambient sounds | Apple SoundAnalysis (`SNAudioStreamAnalyzer`) | On-device, free, no API key, handles common sounds |

## New Files

### `Sources/BantiCore/AudioTypes.swift`

Defines all audio-specific protocols, events, and state types. Mirrors `PerceptionTypes.swift`.

**Protocols:**

```swift
// Mirrors PerceptionDispatcher. MicrophoneCapture depends on this, not the concrete actor.
// Sendable required: AVAudioEngine tap calls dispatch() from an audio thread outside any actor isolation.
// Data is Sendable; AudioRouter (an actor) satisfies Sendable via actor isolation.
public protocol AudioChunkDispatcher: AnyObject, Sendable {
    func dispatch(pcmChunk: Data) async   // 16kHz mono Int16
}
```

**Events** (internal to AudioRouter, not currently stored):

```swift
public enum AudioEvent {
    case speechTranscribed(text: String, speakerID: Int?, isFinal: Bool, confidence: Float)
    case voiceEmotionDetected(emotions: [(label: String, score: Float)])
    case soundClassified(label: String, confidence: Float)
    case silence
}
```

**State types** (all `Codable` — required for `PerceptionContext.snapshotJSON()`):

```swift
public struct SpeechState: Codable {
    public let transcript: String
    public let speakerID: Int?
    public let isFinal: Bool
    public let confidence: Float
    public let updatedAt: Date
}

public struct VoiceEmotionState: Codable {
    public struct Emotion: Codable {
        public let label: String
        public let score: Float
    }
    public let emotions: [Emotion]
    public let updatedAt: Date
}

public struct SoundState: Codable {
    public let label: String
    public let confidence: Float
    public let updatedAt: Date
}
```

### `Sources/BantiCore/MicrophoneCapture.swift`

- `AVAudioEngine` tap on `inputNode` at the hardware's native format
- **Downsampling via `AVAudioConverter`:** installs a converter from the hardware format to 16kHz mono `AVAudioPCMBuffer`, then converts Float32 → Int16 (linear16) before packaging as `Data`
- Calls `dispatcher.dispatch(pcmChunk:)` on each ~20ms converted chunk. The AVAudioEngine tap block is synchronous, so this must be wrapped: `Task { await dispatcher.dispatch(pcmChunk: chunk) }`
- Passes the native-format `AVAudioPCMBuffer` (pre-conversion) to `SoundClassifier` directly on each tap callback
- `start()` / `stop()` lifecycle; requests microphone permission and logs a clear error + exits if denied
- Update `Info.plist` `NSMicrophoneUsageDescription` from `"Banti will use the microphone in a future version."` to `"Banti uses the microphone to listen, transcribe speech, and understand the room."`

**AVAudioConverter setup:**
```
inputFormat  = inputNode.outputFormat(forBus: 0)   // hardware native
outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
converter    = AVAudioConverter(from: inputFormat, to: outputFormat)
```

### `Sources/BantiCore/AudioRouter.swift`

Actor. Mirrors `PerceptionRouter`. Conforms to `AudioChunkDispatcher`. Receives 16kHz Int16 PCM chunks, maintains a rolling ~3s buffer for Hume, dispatches to Deepgram.

- Passes every chunk to `DeepgramStreamer.send(chunk)` (streaming)
- Accumulates chunks into `humeBuffer: Data`; flushes to `HumeVoiceAnalyzer` when buffer reaches ~3s (96,000 bytes at 16kHz Int16 mono = 3s × 16000 × 2)
- `configure()` reads `DEEPGRAM_API_KEY` and `HUME_API_KEY` from env; logs clear warnings and disables the respective analyzer if a key is absent
- **Graceful degradation:** if `DEEPGRAM_API_KEY` is missing, `DeepgramStreamer` is `nil` — chunks are still buffered and sent to Hume, and `SoundClassifier` continues running. If both keys are absent, `MicrophoneCapture` still runs (SoundClassifier needs it).

### `Sources/BantiCore/DeepgramStreamer.swift`

- Connects to `wss://api.deepgram.com/v1/listen`
- Query string: `model=nova-2&diarize=true&punctuate=true&encoding=linear16&sample_rate=16000&channels=1`
- Sends raw PCM `Data` on each chunk via `URLSessionWebSocketTask.Message.data`
- **KeepAlive:** when no audio chunk arrives for 8 seconds (silence detection), sends `{"type": "KeepAlive"}` text message to prevent Deepgram's 10s idle timeout from closing the connection
- Parses Deepgram JSON response; emits `SpeechState` only on `is_final: true` (ignores interim results to reduce noise)
- **Auto-reconnect:** exponential backoff on disconnect (1s, 2s, 4s, 8s, max 30s), logs warning on each attempt
- **Reconnect buffer:** on disconnect, retains up to 5s of recent PCM chunks (~156 KB / 160,000 bytes at 16kHz × 1 channel × 2 bytes/sample × 5s). On reconnect, discards the buffer (replaying to Deepgram would produce duplicate/out-of-order transcripts). If silence persists > 5s during disconnect, stops buffering and drops new chunks until reconnected.

**Deepgram response shape:**
```json
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
```
Speaker ID is extracted from `words[0].speaker` (first word's speaker as a heuristic for the utterance).

### `Sources/BantiCore/HumeVoiceAnalyzer.swift`

- Accumulates 16kHz Int16 mono PCM chunks into ~3s segments
- Wraps each segment in a minimal RIFF/WAV header before base64-encoding
- **Connection model:** connect-per-segment (same pattern as existing `HumeEmotionAnalyzer`): open WebSocket, send one JSON message, read one response, close. This avoids reconnect logic at the cost of ~100ms TLS overhead per 3s segment — acceptable for a non-streaming use case.
- Sends to `wss://api.hume.ai/v0/stream/models?api_key=<HUME_API_KEY>` (key in query param, matching the pattern in `HumeEmotionAnalyzer`) with body `{"models": {"prosody": {}}, "data": "<base64 wav>"}`
- **Parses prosody response** (distinct from face emotion response):
  ```json
  { "prosody": { "predictions": [{ "emotions": [{ "name": "Joy", "score": 0.87 }] }] } }
  ```
  Maps `predictions[0].emotions` → `VoiceEmotionState`
- Throttled: fires at most once every 3s

**WAV header (44 bytes, little-endian) for 16kHz mono Int16:**

| Offset | Size | Value |
|--------|------|-------|
| 0 | 4 | `RIFF` |
| 4 | 4 | total file size − 8 (or `0xFFFFFFFF` for unknown-length streams) |
| 8 | 4 | `WAVE` |
| 12 | 4 | `fmt ` |
| 16 | 4 | `16` (PCM subchunk size) |
| 20 | 2 | `1` (PCM audio format) |
| 22 | 2 | `1` (mono) |
| 24 | 4 | `16000` (sample rate) |
| 28 | 4 | `32000` (byte rate = 16000 × 1 × 2) |
| 32 | 2 | `2` (block align = channels × bits/8) |
| 34 | 2 | `16` (bits per sample) |
| 36 | 4 | `data` |
| 40 | 4 | PCM data byte count |
| 44 | N | PCM data |

### `Sources/BantiCore/SoundClassifier.swift`

- Receives native-format `AVAudioPCMBuffer` directly from `MicrophoneCapture` (before downsampling)
- Holds a `SNAudioStreamAnalyzer` initialized with `inputFormat` matching the hardware format
- Maintains a monotonically increasing `framePosition: AVAudioFramePosition` counter across all calls — never resets it; increments by `buffer.frameLength` after each call: `framePosition += AVAudioFramePosition(buffer.frameLength)`
- Calls `analyzer.analyze(buffer, atAudioFramePosition: framePosition)` on a dedicated serial `DispatchQueue`
- Emits `SoundState` via a callback when confidence > 0.7, throttled to once per second
- `SoundClassifier` does not conform to `AudioChunkDispatcher` — it has its own `analyze(buffer:)` interface taking `AVAudioPCMBuffer`

## Modified Files

### `Sources/BantiCore/PerceptionTypes.swift`

Add to `PerceptionObservation` enum:
```swift
case speech(SpeechState)
case voiceEmotion(VoiceEmotionState)
case sound(SoundState)
```

### `Sources/BantiCore/PerceptionContext.swift`

Add fields:
```swift
public var speech:       SpeechState?
public var voiceEmotion: VoiceEmotionState?
public var sound:        SoundState?
```

Add to `update()` switch (must be exhaustive — Swift requires all cases):
```swift
case .speech(let s):      speech = s
case .voiceEmotion(let s): voiceEmotion = s
case .sound(let s):       sound = s
```

Add to `snapshotJSON()`:
```swift
if let s = speech      { dict["speech"]      = encodable(s) }
if let v = voiceEmotion { dict["voiceEmotion"] = encodable(v) }
if let s = sound       { dict["sound"]       = encodable(s) }
```

**Design note:** audio observation cases are added to the existing `PerceptionObservation` enum in `PerceptionTypes.swift` rather than a separate audio enum. This keeps `PerceptionContext.update()` as a single dispatch point and the snapshot logger uniform. The file will be renamed to a more general name (e.g., `ContextTypes.swift`) in a future cleanup pass, but is out of scope here.

### `Sources/BantiCore/Logger.swift`

Add color entries for new log sources:
- `"deepgram"` → cyan (matches speech/transcription)
- `"hume-voice"` → magenta (matches existing `"hume"` for face emotion)
- `"sound"` → yellow
- `"audio"` → white (generic audio system messages)

### `Sources/banti/main.swift`

```swift
let audioRouter = AudioRouter(context: context, logger: logger)
Task { await audioRouter.configure() }
let soundClassifier = SoundClassifier(context: context, logger: logger)
let micCapture = MicrophoneCapture(dispatcher: audioRouter, soundClassifier: soundClassifier, logger: logger)
micCapture.start()
```

### `Info.plist`

Update `NSMicrophoneUsageDescription`:
```
"Banti uses the microphone to listen, transcribe speech, and understand the room."
```

## Data Flow Detail

```
AVAudioEngine inputNode tap (hardware rate)
  │
  ├── native AVAudioPCMBuffer → SoundClassifier.analyze(buffer:) [on serial queue]
  │       → SNAudioStreamAnalyzer → if confidence > 0.7, throttled 1s
  │       → context.update(.sound(...))
  │
  └── AVAudioConverter → 16kHz mono Int16 → ~20ms Data chunks
          → AudioRouter.dispatch(pcmChunk:)
                │
                ├── DeepgramStreamer.send(chunk) [streaming WebSocket]
                │       → on is_final JSON → context.update(.speech(...))
                │
                └── humeBuffer.append(chunk)
                      if humeBuffer >= 3s (96,000 bytes)
                        → HumeVoiceAnalyzer.analyze(pcm:)
                        → wrap in WAV → base64 → Hume WebSocket
                        → on prosody JSON → context.update(.voiceEmotion(...))
```

## Environment Variables

| Variable | Required | Purpose |
|---|---|---|
| `DEEPGRAM_API_KEY` | For transcription | Deepgram streaming API |
| `HUME_API_KEY` | Already required | Hume Speech Prosody (same key as face emotion) |

## Error Handling

- **Deepgram disconnect:** exponential backoff (1s→2s→4s→8s→30s max), log warning per attempt. Buffer up to 5s (~156 KB) of PCM in memory; discard on reconnect (no replay to avoid duplicates). Stop buffering after 5s of disconnect.
- **Deepgram idle timeout:** send `{"type": "KeepAlive"}` after 8s of silence to prevent the 10s server-side timeout.
- **Hume failure:** log warning, skip that segment, retry on next 3s flush cycle.
- **Microphone permission denied:** log error with clear message and call `exit(1)`.
- **SoundClassifier error:** log warning, continue (on-device, non-critical).

## Testing

- `AudioRouter` buffer accumulation and flush threshold (96,000 bytes = 3s) — inject mock `DeepgramStreamer` and `HumeVoiceAnalyzer` conforming to protocols
- `AudioRouter` graceful degradation when API keys are absent — confirm Hume and Deepgram are nil, SoundClassifier still runs
- `DeepgramStreamer` JSON parsing — fixture responses for `is_final: true`, `is_final: false`, missing speaker field
- `DeepgramStreamer` KeepAlive — verify `{"type":"KeepAlive"}` is sent after 8s silence simulation
- `HumeVoiceAnalyzer` WAV header construction — verify all 44-byte header fields match the spec table above
- `HumeVoiceAnalyzer` response parsing — fixture for `prosody.predictions[0].emotions` shape
- `SoundClassifier` frame position monotonicity — verify counter never resets across multiple `analyze(buffer:)` calls
- `MicrophoneCapture` permission-denied path — inject a mock `AVAudioSession` or test the permission callback directly via the `AudioCaptureDelegate` protocol (note: `AVAudioEngine` is a concrete class with no protocol; do not attempt to subclass/mock it directly)
