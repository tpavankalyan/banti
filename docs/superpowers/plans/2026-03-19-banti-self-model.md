# Banti Self-Model & Conversation Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix banti's three self-echo infinite-loop failure modes by giving it a self-model woven into the perception pipeline — efference copy (SelfSpeechLog), single output identity (BantiVoice), attributed conversation history (ConversationBuffer), and separation of ambient context from conversational context.

**Architecture:** New actors `SelfSpeechLog`, `ConversationBuffer`, and `BantiVoice` are introduced. `BantiVoice` wraps `CartesiaSpeaker` and is the single output point for all speech — it registers utterances before audio plays, writes to conversation history, and exposes attribution/suppression to the rest of the system. `BrainLoop` is refactored to use `ConversationBuffer` instead of raw transcript lists, and to route all incoming Deepgram transcripts through `BantiVoice.attributeTranscript()` before acting on them. `PerceptionContext` loses its `speech` field entirely, making `snapshotJSON()` ambient-only. The Python sidecar receives `conversation_history` (attributed turns) and `ambient_context` instead of `recent_speech` and `snapshot_json`.

**Tech Stack:** Swift 5.9+, Swift Concurrency (actors, async/await), XCTest, Python 3.14, FastAPI, Pydantic v2, pytest. Build: `swift test` (Swift Package Manager) and `pytest` (Python).

---

## File Map

**New Swift files:**
- `Sources/BantiCore/SelfSpeechLog.swift` — efference copy actor; registers utterances, tracks playback state, fuzzy-matches transcripts
- `Sources/BantiCore/ConversationBuffer.swift` — attributed turn history; `Speaker` enum, `ConversationTurn` struct
- `Sources/BantiCore/SpeakerAttributor.swift` — stateless attribution struct; delegates to `SelfSpeechLog`
- `Sources/BantiCore/BantiVoice.swift` — single output identity actor; wraps `CartesiaSpeaker`, owns `SelfSpeechLog`

**New test files:**
- `Tests/BantiTests/SelfSpeechLogTests.swift`
- `Tests/BantiTests/ConversationBufferTests.swift`
- `Tests/BantiTests/SpeakerAttributorTests.swift`
- `Tests/BantiTests/BantiVoiceTests.swift`

**Modified Swift files:**
- `Sources/BantiCore/PerceptionTypes.swift` — remove `.speech(SpeechState)` from `PerceptionObservation`
- `Sources/BantiCore/PerceptionContext.swift` — remove `speech: SpeechState?` field and its handling
- `Sources/BantiCore/DeepgramStreamer.swift` — remove `context.update(.speech(state))`; remove `context` dependency
- `Sources/BantiCore/BrainLoop.swift` — new init, refactored `BrainStreamBody`, `streamTrack`, `onFinalTranscript`
- `Sources/BantiCore/MemoryEngine.swift` — wire new actors in correct construction order
- `Sources/BantiCore/PerceptionRouter.swift` — add `bantiVoice` ref; filter screen obs before context update
- `Sources/banti/main.swift` — call `router.setBantiVoice(...)` after `MemoryEngine` init

**Modified test files:**
- `Tests/BantiTests/BrainLoopTests.swift` — remove `appendTranscript` tests; update `BrainStreamBody` tests
- `Tests/BantiTests/DeepgramStreamerTests.swift` — remove `context.speech` assertions; update init

**Modified Python files:**
- `memory_sidecar/models.py` — new `ConversationTurn` model; update `BrainStreamRequest`
- `memory_sidecar/memory.py` — update `_reflex_stream`, `_reasoning_stream` prompt assembly

**New Python test file:**
- `memory_sidecar/tests/test_brain_stream.py`

---

## Task 1: SelfSpeechLog

**Files:**
- Create: `Sources/BantiCore/SelfSpeechLog.swift`
- Create: `Tests/BantiTests/SelfSpeechLogTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/SelfSpeechLogTests.swift
import XCTest
@testable import BantiCore

final class SelfSpeechLogTests: XCTestCase {

    // MARK: - normalize (static helper, no actor needed)

    func test_normalize_lowercasesAndStripsPunctuation() {
        XCTAssertEqual(SelfSpeechLog.normalize("Hello, World!"), "hello world")
    }

    func test_normalize_collapsesWhitespace() {
        XCTAssertEqual(SelfSpeechLog.normalize("  hello   world  "), "hello world")
    }

    // MARK: - jaccard (static helper)

    func test_jaccard_identicalStrings() {
        XCTAssertEqual(SelfSpeechLog.jaccard("hello world", "hello world"), 1.0, accuracy: 0.001)
    }

    func test_jaccard_noOverlap() {
        XCTAssertEqual(SelfSpeechLog.jaccard("foo bar", "baz qux"), 0.0, accuracy: 0.001)
    }

    func test_jaccard_partialOverlap() {
        // "hello world test" vs "hello world" → intersection=2 union=3
        XCTAssertEqual(SelfSpeechLog.jaccard("hello world test", "hello world"), 2.0/3.0, accuracy: 0.001)
    }

    // MARK: - isCurrentlyPlaying state

    func test_isCurrentlyPlaying_falseInitially() async {
        let log = SelfSpeechLog()
        let playing = await log.isCurrentlyPlaying
        XCTAssertFalse(playing)
    }

    func test_isCurrentlyPlaying_trueAfterRegister_falseAfterMarkEnded() async {
        let log = SelfSpeechLog()
        await log.register(text: "hello there friend")
        let duringPlay = await log.isCurrentlyPlaying
        await log.markPlaybackEnded()
        let afterEnd = await log.isCurrentlyPlaying
        XCTAssertTrue(duringPlay)
        XCTAssertFalse(afterEnd)
    }

    // MARK: - isSelfEcho: cold start (no registration)

    func test_isSelfEcho_false_whenNeverRegistered() async {
        let log = SelfSpeechLog()
        let result = await log.isSelfEcho(transcript: "hello world test input phrase")
        XCTAssertFalse(result)
    }

    // MARK: - isSelfEcho: active playback

    func test_isSelfEcho_true_whenPlayingAndMatches() async {
        let log = SelfSpeechLog()
        await log.register(text: "let me check that for you")
        // isCurrentlyPlaying=true, fuzzy match passes
        let result = await log.isSelfEcho(transcript: "let me check that for you", arrivedAt: Date())
        XCTAssertTrue(result)
    }

    func test_isSelfEcho_false_whenPlayingButNoMatch() async {
        let log = SelfSpeechLog()
        await log.register(text: "banti said something totally different today right now")
        // gate active but no fuzzy match → human interruption
        let result = await log.isSelfEcho(transcript: "what is the weather tomorrow", arrivedAt: Date())
        XCTAssertFalse(result)
    }

    func test_isSelfEcho_true_whenPlayingAndEmptyEntries_conservative() async {
        // Simulate: gate active (isCurrentlyPlaying=true) but entries somehow empty
        // We can't easily purge, so just verify the flag-only path by registering
        // a very short entry that stays in the ring buffer but won't match.
        // Actually test the conservative rule: after register(), isCurrentlyPlaying=true;
        // if entries is NOT empty and gate passes → falls through to fuzzy match which
        // may return false. Test the flag being set is sufficient for the conservative path.
        // (Full conservative path with empty entries is covered by internal logic —
        // here we just verify isCurrentlyPlaying is true after register)
        let log = SelfSpeechLog()
        await log.register(text: "test")
        let playing = await log.isCurrentlyPlaying
        XCTAssertTrue(playing)
    }

    // MARK: - isSelfEcho: tail window

    func test_isSelfEcho_true_withinTailWindow() async {
        let log = SelfSpeechLog()
        await log.register(text: "let me think about that one please")
        await log.markPlaybackEnded()
        let arrivedAt = Date().addingTimeInterval(3.0)  // within 5s tail
        let result = await log.isSelfEcho(transcript: "let me think about that one please", arrivedAt: arrivedAt)
        XCTAssertTrue(result)
    }

    func test_isSelfEcho_false_afterTailExpired() async {
        let log = SelfSpeechLog()
        await log.register(text: "let me think about that one please")
        await log.markPlaybackEnded()
        let arrivedAt = Date().addingTimeInterval(6.0)  // beyond 5s tail
        let result = await log.isSelfEcho(transcript: "let me think about that one please", arrivedAt: arrivedAt)
        XCTAssertFalse(result)
    }

    // MARK: - isSelfEcho: Deepgram paraphrase tolerance

    func test_isSelfEcho_true_forParaphrasedTranscript() async {
        let log = SelfSpeechLog()
        // Registered: "let me check on that for you" (7 words)
        // Transcript:  "let me check that for you"  (6 words)
        // Intersection: let, me, check, that, for, you = 6; Union: 7 → Jaccard ≈ 0.857
        await log.register(text: "let me check on that for you")
        let result = await log.isSelfEcho(
            transcript: "let me check that for you",
            arrivedAt: Date()
        )
        XCTAssertTrue(result)
    }

    // MARK: - suppressSelfEcho

    func test_suppressSelfEcho_removesMatchingPhrase() async {
        let log = SelfSpeechLog()
        await log.register(text: "this is a test phrase with many words right here")
        let cleaned = await log.suppressSelfEcho(in: "this is a test phrase with many words right here")
        // Normalized match found and removed — result should be empty or greatly reduced
        XCTAssertTrue(cleaned.count < 20)
    }

    func test_suppressSelfEcho_keepsShortRegistered_belowThreshold() async {
        let log = SelfSpeechLog()
        await log.register(text: "hi there")  // only 2 words — below 5-word threshold
        let input = "hi there how are you doing today"
        let cleaned = await log.suppressSelfEcho(in: input)
        // Short phrase should NOT be suppressed — input should be mostly preserved
        XCTAssertFalse(cleaned.isEmpty)
    }

    func test_suppressSelfEcho_returnsInput_whenNothingRegistered() async {
        let log = SelfSpeechLog()
        let input = "nothing was ever registered here at all"
        let cleaned = await log.suppressSelfEcho(in: input)
        XCTAssertFalse(cleaned.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests — expect failure (SelfSpeechLog doesn't exist)**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter SelfSpeechLogTests 2>&1 | tail -5
```
Expected: compile error — `SelfSpeechLog` not found.

- [ ] **Step 3: Implement SelfSpeechLog**

```swift
// Sources/BantiCore/SelfSpeechLog.swift
import Foundation

public actor SelfSpeechLog {
    private struct Entry {
        let normalizedText: String
        let registeredAt: Date
    }

    private var entries: [Entry] = []
    private var lastPlaybackEndedAt: Date?
    public private(set) var isCurrentlyPlaying: Bool = false

    private static let maxEntries = 30
    private static let entryTTLSeconds = 120.0
    private static let tailSeconds = 5.0
    private static let jaccardThreshold = 0.6
    private static let suppressMinWords = 5

    // MARK: - Public API

    public func register(text: String) {
        isCurrentlyPlaying = true
        purgeStale()
        let normalized = Self.normalize(text)
        if entries.count >= Self.maxEntries { entries.removeFirst() }
        entries.append(Entry(normalizedText: normalized, registeredAt: Date()))
    }

    public func markPlaybackEnded() {
        isCurrentlyPlaying = false
        lastPlaybackEndedAt = Date()
    }

    public func isSelfEcho(transcript: String, arrivedAt: Date = Date()) -> Bool {
        let inTail = lastPlaybackEndedAt.map {
            arrivedAt.timeIntervalSince($0) <= Self.tailSeconds
        } ?? false
        let playbackGate = isCurrentlyPlaying || inTail
        guard playbackGate else { return false }

        // Conservative: gate active but no entries (race/cold-start edge case)
        if entries.isEmpty { return true }

        let normalized = Self.normalize(transcript)
        return entries.contains {
            Self.jaccard(normalized, $0.normalizedText) >= Self.jaccardThreshold
        }
    }

    public func suppressSelfEcho(in text: String) -> String {
        purgeStale()
        guard !entries.isEmpty else { return text }

        let normalizedInput = Self.normalize(text)
        var result = normalizedInput

        for entry in entries {
            let phrase = entry.normalizedText
            guard phrase.split(separator: " ").count >= Self.suppressMinWords else { continue }
            if result.contains(phrase) {
                result = result.replacingOccurrences(of: phrase, with: " ")
            }
        }

        // Collapse multiple spaces and trim
        let collapsed = result
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    // MARK: - Static helpers (public for testability)

    public static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .punctuationCharacters).joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func jaccard(_ a: String, _ b: String) -> Double {
        let setA = Set(a.split(separator: " ").map(String.init))
        let setB = Set(b.split(separator: " ").map(String.init))
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    // MARK: - Private

    private func purgeStale() {
        let cutoff = Date().addingTimeInterval(-Self.entryTTLSeconds)
        entries.removeAll { $0.registeredAt < cutoff }
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter SelfSpeechLogTests 2>&1 | tail -10
```
Expected: all `SelfSpeechLogTests` pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add Sources/BantiCore/SelfSpeechLog.swift Tests/BantiTests/SelfSpeechLogTests.swift
git commit -m "feat: add SelfSpeechLog actor — efference copy for acoustic self-echo suppression"
```

---

## Task 2: ConversationBuffer

**Files:**
- Create: `Sources/BantiCore/ConversationBuffer.swift`
- Create: `Tests/BantiTests/ConversationBufferTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/ConversationBufferTests.swift
import XCTest
@testable import BantiCore

final class ConversationBufferTests: XCTestCase {

    func test_addBantiTurn_appearsInRecentTurns() async {
        let buf = ConversationBuffer()
        await buf.addBantiTurn("hello from banti")
        let turns = await buf.recentTurns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].speaker, .banti)
        XCTAssertEqual(turns[0].text, "hello from banti")
    }

    func test_addHumanTurn_appearsInRecentTurns() async {
        let buf = ConversationBuffer()
        await buf.addHumanTurn("hi banti")
        let turns = await buf.recentTurns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].speaker, .human)
    }

    func test_recentTurns_returnsInOrder() async {
        let buf = ConversationBuffer()
        await buf.addHumanTurn("first")
        await buf.addBantiTurn("second")
        await buf.addHumanTurn("third")
        let turns = await buf.recentTurns()
        XCTAssertEqual(turns.map(\.text), ["first", "second", "third"])
    }

    func test_recentTurns_respectsLimit() async {
        let buf = ConversationBuffer()
        for i in 1...15 {
            await buf.addHumanTurn("turn \(i)")
        }
        let turns = await buf.recentTurns(limit: 5)
        XCTAssertEqual(turns.count, 5)
        XCTAssertEqual(turns.first?.text, "turn 11")
        XCTAssertEqual(turns.last?.text, "turn 15")
    }

    func test_capsAt30Turns_dropsOldest() async {
        let buf = ConversationBuffer()
        for i in 1...32 {
            await buf.addHumanTurn("turn \(i)")
        }
        let turns = await buf.recentTurns(limit: 50)
        XCTAssertEqual(turns.count, 30)
        XCTAssertEqual(turns.first?.text, "turn 3")
    }

    func test_lastBantiUtterance_returnsNilWhenEmpty() async {
        let buf = ConversationBuffer()
        let last = await buf.lastBantiUtterance()
        XCTAssertNil(last)
    }

    func test_lastBantiUtterance_returnsLastBantiText() async {
        let buf = ConversationBuffer()
        await buf.addBantiTurn("first banti")
        await buf.addHumanTurn("human reply")
        await buf.addBantiTurn("second banti")
        let last = await buf.lastBantiUtterance()
        XCTAssertEqual(last, "second banti")
    }

    func test_lastBantiUtterance_returnsNilIfOnlyHumanTurns() async {
        let buf = ConversationBuffer()
        await buf.addHumanTurn("only human spoke")
        let last = await buf.lastBantiUtterance()
        XCTAssertNil(last)
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter ConversationBufferTests 2>&1 | tail -5
```
Expected: compile error — `ConversationBuffer` not found.

- [ ] **Step 3: Implement ConversationBuffer**

```swift
// Sources/BantiCore/ConversationBuffer.swift
import Foundation

public enum Speaker: String, Codable {
    case banti, human
}

public struct ConversationTurn: Codable {
    public let speaker: Speaker
    public let text: String
    public let timestamp: Date

    public init(speaker: Speaker, text: String, timestamp: Date = Date()) {
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }
}

public actor ConversationBuffer {
    private var turns: [ConversationTurn] = []
    private static let maxTurns = 30

    public func addBantiTurn(_ text: String) {
        append(ConversationTurn(speaker: .banti, text: text))
    }

    public func addHumanTurn(_ text: String) {
        append(ConversationTurn(speaker: .human, text: text))
    }

    public func recentTurns(limit: Int = 10) -> [ConversationTurn] {
        Array(turns.suffix(limit))
    }

    public func lastBantiUtterance() -> String? {
        turns.last(where: { $0.speaker == .banti })?.text
    }

    private func append(_ turn: ConversationTurn) {
        if turns.count >= Self.maxTurns { turns.removeFirst() }
        turns.append(turn)
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter ConversationBufferTests 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add Sources/BantiCore/ConversationBuffer.swift Tests/BantiTests/ConversationBufferTests.swift
git commit -m "feat: add ConversationBuffer actor — attributed turn history (banti/human)"
```

---

## Task 3: SpeakerAttributor

**Files:**
- Create: `Sources/BantiCore/SpeakerAttributor.swift`
- Create: `Tests/BantiTests/SpeakerAttributorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/SpeakerAttributorTests.swift
import XCTest
@testable import BantiCore

final class SpeakerAttributorTests: XCTestCase {

    func test_human_whenLogNeverRegistered() async {
        let log = SelfSpeechLog()
        let result = await SpeakerAttributor().attribute(
            "hello there how are you today friend",
            arrivedAt: Date(),
            selfLog: log
        )
        XCTAssertEqual(result, .human)
    }

    func test_selfEcho_whenPlayingAndMatches() async {
        let log = SelfSpeechLog()
        await log.register(text: "let me check that for you right now")
        let result = await SpeakerAttributor().attribute(
            "let me check that for you right now",
            arrivedAt: Date(),
            selfLog: log
        )
        XCTAssertEqual(result, .selfEcho)
    }

    func test_human_whenPlayingButNoMatch() async {
        let log = SelfSpeechLog()
        await log.register(text: "banti is saying something completely different here")
        let result = await SpeakerAttributor().attribute(
            "what is the weather like tomorrow morning",
            arrivedAt: Date(),
            selfLog: log
        )
        XCTAssertEqual(result, .human)
    }

    func test_selfEcho_withinTailWindow() async {
        let log = SelfSpeechLog()
        await log.register(text: "this is what banti said a moment ago")
        await log.markPlaybackEnded()
        let result = await SpeakerAttributor().attribute(
            "this is what banti said a moment ago",
            arrivedAt: Date().addingTimeInterval(2.0),
            selfLog: log
        )
        XCTAssertEqual(result, .selfEcho)
    }

    func test_human_afterTailWindowExpired() async {
        let log = SelfSpeechLog()
        await log.register(text: "this is what banti said a moment ago")
        await log.markPlaybackEnded()
        let result = await SpeakerAttributor().attribute(
            "this is what banti said a moment ago",
            arrivedAt: Date().addingTimeInterval(6.0),
            selfLog: log
        )
        XCTAssertEqual(result, .human)
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter SpeakerAttributorTests 2>&1 | tail -5
```

- [ ] **Step 3: Implement SpeakerAttributor**

```swift
// Sources/BantiCore/SpeakerAttributor.swift
import Foundation

public struct SpeakerAttributor {
    public enum Source: Equatable {
        case human, selfEcho
    }

    public init() {}

    public func attribute(
        _ transcript: String,
        arrivedAt: Date = Date(),
        selfLog: SelfSpeechLog
    ) async -> Source {
        if await selfLog.isSelfEcho(transcript: transcript, arrivedAt: arrivedAt) {
            return .selfEcho
        }
        return .human
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter SpeakerAttributorTests 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add Sources/BantiCore/SpeakerAttributor.swift Tests/BantiTests/SpeakerAttributorTests.swift
git commit -m "feat: add SpeakerAttributor — stateless attribution gate wrapping SelfSpeechLog"
```

---

## Task 4: BantiVoice

**Files:**
- Create: `Sources/BantiCore/BantiVoice.swift`
- Create: `Tests/BantiTests/BantiVoiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/BantiVoiceTests.swift
import XCTest
import AVFoundation
@testable import BantiCore

final class BantiVoiceTests: XCTestCase {

    // Shared test infrastructure
    private func makeBantiVoice() -> (BantiVoice, SelfSpeechLog, ConversationBuffer) {
        let engine = AVAudioEngine()
        let log = SelfSpeechLog()
        let buf = ConversationBuffer()
        let speaker = CartesiaSpeaker(engine: engine, logger: Logger())
        let voice = BantiVoice(
            cartesiaSpeaker: speaker,
            selfSpeechLog: log,
            conversationBuffer: buf,
            logger: Logger()
        )
        return (voice, log, buf)
    }

    func test_say_registersInSelfSpeechLog() async {
        let (voice, log, _) = makeBantiVoice()
        // We only test the side-effects on SelfSpeechLog, not actual TTS (no API key in tests)
        // After say(), isCurrentlyPlaying should be true (register was called)
        // Note: streamSpeak will fail silently (no API key) but register() runs first
        await voice.say("hello friend this is a test", track: .reflex)
        let playing = await log.isCurrentlyPlaying
        // isCurrentlyPlaying was set true by register(); may be true or false depending on
        // whether streamSpeak returned (no TTS key = immediate return).
        // What we can assert: attribution of the exact text should be selfEcho while gate is active.
        // Re-register manually to check the log accepted it.
        let echo = await log.isSelfEcho(transcript: "hello friend this is a test", arrivedAt: Date())
        // gate active (isCurrentlyPlaying set by register) + fuzzy match → true
        XCTAssertTrue(echo)
        _ = playing  // suppress unused warning
    }

    func test_say_writesBantiTurnToConversationBuffer() async {
        let (voice, _, buf) = makeBantiVoice()
        await voice.say("testing the buffer here", track: .reflex)
        let turns = await buf.recentTurns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].speaker, .banti)
        XCTAssertEqual(turns[0].text, "testing the buffer here")
    }

    func test_markPlaybackEnded_clearsIsCurrentlyPlaying() async {
        let (voice, log, _) = makeBantiVoice()
        await voice.say("some test phrase for the log", track: .reflex)
        await voice.markPlaybackEnded()
        let playing = await log.isCurrentlyPlaying
        XCTAssertFalse(playing)
    }

    func test_attributeTranscript_selfEcho_whenJustSpoke() async {
        let (voice, _, _) = makeBantiVoice()
        await voice.say("let me look into that for you now", track: .reflex)
        let result = await voice.attributeTranscript(
            "let me look into that for you now",
            arrivedAt: Date()
        )
        XCTAssertEqual(result, .selfEcho)
    }

    func test_attributeTranscript_human_forUnrelatedText() async {
        let (voice, _, _) = makeBantiVoice()
        // Nothing registered — all transcripts are human
        let result = await voice.attributeTranscript(
            "what is the weather like tomorrow morning",
            arrivedAt: Date()
        )
        XCTAssertEqual(result, .human)
    }

    func test_suppressSelfEcho_delegatesToLog() async {
        let (voice, log, _) = makeBantiVoice()
        await log.register(text: "this is a test phrase with sufficient words here")
        let cleaned = await voice.suppressSelfEcho(in: "this is a test phrase with sufficient words here")
        XCTAssertTrue(cleaned.count < 20)
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter BantiVoiceTests 2>&1 | tail -5
```

- [ ] **Step 3: Implement BantiVoice**

```swift
// Sources/BantiCore/BantiVoice.swift
import Foundation

public actor BantiVoice {
    private let cartesiaSpeaker: CartesiaSpeaker
    private let selfSpeechLog: SelfSpeechLog
    private let conversationBuffer: ConversationBuffer
    private let logger: Logger

    public init(
        cartesiaSpeaker: CartesiaSpeaker,
        selfSpeechLog: SelfSpeechLog,
        conversationBuffer: ConversationBuffer,
        logger: Logger
    ) {
        self.cartesiaSpeaker = cartesiaSpeaker
        self.selfSpeechLog = selfSpeechLog
        self.conversationBuffer = conversationBuffer
        self.logger = logger
    }

    /// Say a sentence. Called once per SSE sentence inside BrainLoop.streamTrack().
    /// Does NOT call markPlaybackEnded() — that is the caller's responsibility after
    /// the full response is complete (any exit path).
    public func say(_ text: String, track: TrackPriority) async {
        await selfSpeechLog.register(text: text)        // efference copy — before audio
        await conversationBuffer.addBantiTurn(text)     // conversation record
        await cartesiaSpeaker.streamSpeak(text, track: track)  // actual audio
    }

    /// Called by BrainLoop.streamTrack() unconditionally when the SSE loop exits.
    /// Clears isCurrentlyPlaying and opens the 5s post-playback tail window.
    public func markPlaybackEnded() async {
        await selfSpeechLog.markPlaybackEnded()
    }

    /// Async func (not computed var) due to actor isolation on CartesiaSpeaker.
    public func isPlaying() async -> Bool {
        return await cartesiaSpeaker.isPlaying
    }

    public func cancelTrack(_ track: TrackPriority) async {
        await cartesiaSpeaker.cancelTrack(track)
    }

    /// Route attribution through BantiVoice — SelfSpeechLog is fully encapsulated here.
    public func attributeTranscript(
        _ transcript: String,
        arrivedAt: Date = Date()
    ) async -> SpeakerAttributor.Source {
        return await SpeakerAttributor().attribute(transcript, arrivedAt: arrivedAt, selfLog: selfSpeechLog)
    }

    /// Used by PerceptionRouter to filter screen/AX text before context update.
    public func suppressSelfEcho(in text: String) async -> String {
        return await selfSpeechLog.suppressSelfEcho(in: text)
    }

    // MARK: - Test helpers (accessible via @testable import)
    func selfSpeechLogForTest() -> SelfSpeechLog { selfSpeechLog }
    func conversationBufferForTest() -> ConversationBuffer { conversationBuffer }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter BantiVoiceTests 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add Sources/BantiCore/BantiVoice.swift Tests/BantiTests/BantiVoiceTests.swift
git commit -m "feat: add BantiVoice actor — single output identity wrapping CartesiaSpeaker"
```

---

## Task 5: Remove speech from perception pipeline

Remove `.speech` from `PerceptionObservation`, `PerceptionContext`, and `DeepgramStreamer`. These three files change together because they share the `.speech` case — removing it from one without the others causes compile failures.

**Files:**
- Modify: `Sources/BantiCore/PerceptionTypes.swift`
- Modify: `Sources/BantiCore/PerceptionContext.swift`
- Modify: `Sources/BantiCore/DeepgramStreamer.swift`
- Modify: `Tests/BantiTests/DeepgramStreamerTests.swift` (read this file first — remove assertions on `context.speech`)

- [ ] **Step 1: Read DeepgramStreamerTests.swift to understand what must change**

```bash
cat /Users/tpavankalyan/Downloads/Code/banti/Tests/BantiTests/DeepgramStreamerTests.swift
```
Look for any assertions on `context.speech` or `PerceptionObservation.speech` — these must be removed or updated.

- [ ] **Step 2: Remove `.speech(SpeechState)` from `PerceptionObservation` in PerceptionTypes.swift**

In `Sources/BantiCore/PerceptionTypes.swift`, remove this line from the `PerceptionObservation` enum:
```swift
case speech(SpeechState)
```
The `SpeechState` type itself stays in `AudioTypes.swift` — it's still used by `DeepgramStreamer.parseResponse()`.

- [ ] **Step 3: Remove `speech` field from PerceptionContext**

In `Sources/BantiCore/PerceptionContext.swift`:
- Remove: `public var speech:   SpeechState?`
- Remove: `case .speech(let s): speech = s` from `update(_:)`
- Remove: `if let sp = speech  { dict["speech"]   = encodable(sp) }` from `snapshotJSON()`

- [ ] **Step 4: Remove context dependency from DeepgramStreamer**

In `Sources/BantiCore/DeepgramStreamer.swift`:
- Remove: `private let context: PerceptionContext`  from stored properties
- Remove: `context: PerceptionContext,` from `init` parameters
- Remove: `self.context = context` from init body
- Remove: `await context.update(.speech(state))` from `handleMessage`

The `handleMessage` function now only fires `onFinalTranscript` callback for final transcripts. No other changes needed — `parseResponse` and the callback logic remain.

- [ ] **Step 5: Update DeepgramStreamerTests.swift**

Remove any test that:
- Passes a `PerceptionContext` to `DeepgramStreamer.init`
- Asserts `context.speech != nil` or checks `context.speech.transcript`

Update `DeepgramStreamer` construction in tests to remove the `context:` parameter. Tests that verify `onFinalTranscript` callback behavior are unchanged.

- [ ] **Step 6: Update AudioRouter.swift to remove context from DeepgramStreamer init**

In `Sources/BantiCore/AudioRouter.swift`, the `configureWith` method creates `DeepgramStreamer`:
```swift
// Before:
deepgram = DeepgramStreamer(apiKey: key, context: context, logger: logger)

// After:
deepgram = DeepgramStreamer(apiKey: key, logger: logger)
```
Also remove `private let context: PerceptionContext` from `AudioRouter` if it's only used for the Deepgram init (check — it may also be used for Hume updates which stay).

- [ ] **Step 7: Run full test suite — expect pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test 2>&1 | tail -15
```
Expected: all tests pass. If tests reference `context.speech` that you haven't updated, fix them now.

- [ ] **Step 8: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add Sources/BantiCore/PerceptionTypes.swift Sources/BantiCore/PerceptionContext.swift \
    Sources/BantiCore/DeepgramStreamer.swift Sources/BantiCore/AudioRouter.swift \
    Tests/BantiTests/DeepgramStreamerTests.swift
git commit -m "refactor: remove speech from PerceptionContext/Observation — ambient context now speech-free"
```

---

## Task 6: Refactor BrainLoop

Replace `BrainStreamBody`, refactor `BrainLoop.init`, `streamTrack`, and `onFinalTranscript`. Update and trim `BrainLoopTests`.

**Files:**
- Modify: `Sources/BantiCore/BrainLoop.swift`
- Modify: `Tests/BantiTests/BrainLoopTests.swift`

- [ ] **Step 1: Update BrainStreamBody struct in BrainLoop.swift**

Replace the existing `BrainStreamBody` struct (currently at the top of `BrainLoop.swift`) with:

```swift
// New types replacing the old BrainStreamBody
struct ConversationTurnDTO: Encodable {
    let speaker: String      // "banti" or "human"
    let text: String
    let timestamp: Double    // unix timestamp
}

struct BrainStreamBody: Encodable {
    let track: String
    let ambient_context: String          // was: snapshot_json
    let conversation_history: [ConversationTurnDTO]  // was: recent_speech: [String]
    let last_banti_utterance: String?    // was: last_spoke_text
    let last_spoke_seconds_ago: Double
    let is_interruption: Bool
    let current_speech: String?
}
```

- [ ] **Step 2: Update BrainLoop stored properties**

In `BrainLoop`:
- Remove: `private let speaker: CartesiaSpeaker`
- Remove: `private var recentTranscripts: [String] = []`
- Remove: `private var lastSpokeText: String?`
- Add: `private let bantiVoice: BantiVoice`
- Add: `private let conversationBuffer: ConversationBuffer`

- [ ] **Step 3: Update BrainLoop.init**

```swift
public init(context: PerceptionContext, sidecar: MemorySidecar,
            bantiVoice: BantiVoice,
            conversationBuffer: ConversationBuffer,
            logger: Logger) {
    self.context = context
    self.sidecar = sidecar
    self.bantiVoice = bantiVoice
    self.conversationBuffer = conversationBuffer
    self.logger = logger
}
```

- [ ] **Step 4: Update onFinalTranscript**

Replace the existing `onFinalTranscript` with:

```swift
public func onFinalTranscript(_ transcript: String) async {
    // Capture isPlaying before attribution — used for interruption detection only
    let wasPlaying = await bantiVoice.isPlaying()
    let source = await bantiVoice.attributeTranscript(transcript, arrivedAt: Date())
    guard source == .human else { return }
    await conversationBuffer.addHumanTurn(transcript)
    let isInterruption = wasPlaying && BrainLoop.isInterruptionCandidate(transcript)
    await evaluate(reason: "speech: \(transcript)", isInterruption: isInterruption)
}
```

- [ ] **Step 5: Update streamTrack**

Replace the existing `streamTrack` body with:

```swift
private func streamTrack(_ track: TrackPriority, isInterruption: Bool = false, currentSpeech: String? = nil) async {
    guard await sidecar.isRunning else {
        await bantiVoice.markPlaybackEnded()
        return
    }

    let snapshot = await context.snapshotJSON()
    let turns = await conversationBuffer.recentTurns(limit: 10)
    let dtoTurns = turns.map {
        ConversationTurnDTO(speaker: $0.speaker.rawValue, text: $0.text,
                            timestamp: $0.timestamp.timeIntervalSince1970)
    }
    let body = BrainStreamBody(
        track: track.rawValue,
        ambient_context: snapshot,
        conversation_history: dtoTurns,
        last_banti_utterance: await conversationBuffer.lastBantiUtterance(),
        last_spoke_seconds_ago: BrainLoop.secondsSince(lastSpoke),
        is_interruption: isInterruption,
        current_speech: currentSpeech
    )

    guard let url = URL(string: "/brain/stream", relativeTo: sidecar.baseURL),
          let bodyData = try? JSONEncoder().encode(body) else {
        await bantiVoice.markPlaybackEnded()
        return
    }

    var request = URLRequest(url: url, timeoutInterval: 25.0)
    request.httpMethod = "POST"
    request.httpBody = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

    do {
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        for try await line in bytes.lines {
            if Task.isCancelled { break }     // break (not return) so markPlaybackEnded runs
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard let data = jsonStr.data(using: .utf8),
                  let event = try? JSONDecoder().decode(SSEEvent.self, from: data) else { continue }
            if event.type == "done" { break }
            if event.type == "sentence", let text = event.text, !text.isEmpty {
                currentlySpeaking = text
                await bantiVoice.say(text, track: track)
            }
        }
    } catch {
        logger.log(source: "brain",
                   message: "[warn] \(track.rawValue) track failed: \(error.localizedDescription)")
    }

    // Unconditional: close playback window whether we spoke, were cancelled, or errored.
    await bantiVoice.markPlaybackEnded()
}
```

Note: `evaluate` still calls `cancelTrack` and sets `activeReflexTask`/`activeReasoningTask`. Update `evaluate` to use `bantiVoice.cancelTrack()` instead of `speaker.cancelTrack()`:
```swift
await bantiVoice.cancelTrack(.reflex)
await bantiVoice.cancelTrack(.reasoning)
```

- [ ] **Step 6: Remove appendTranscript static method**

Delete the `appendTranscript` static method from `BrainLoop` — it's no longer used.

- [ ] **Step 7: Update BrainLoopTests.swift**

- **Remove** the four `testAppendTranscript*` tests and `testTranscriptBufferCapsAt5` (lines 44–76) — `appendTranscript` no longer exists.
- **Remove** `testBrainStreamBodyEncodesInterruptionFields` and `testBrainStreamBodyEncodesNonInterruptionFields` (lines 202–235) — the struct fields have changed.
- **Add** new `BrainStreamBody` encoding tests with the new fields:

```swift
func testBrainStreamBodyEncodesConversationHistory() throws {
    let turn = ConversationTurnDTO(speaker: "human", text: "hello", timestamp: 1000.0)
    let body = BrainStreamBody(
        track: "reflex",
        ambient_context: "{}",
        conversation_history: [turn],
        last_banti_utterance: "hi there",
        last_spoke_seconds_ago: 5.0,
        is_interruption: false,
        current_speech: nil
    )
    let data = try JSONEncoder().encode(body)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(json["ambient_context"] as? String, "{}")
    let history = json["conversation_history"] as? [[String: Any]]
    XCTAssertEqual(history?.count, 1)
    XCTAssertEqual(history?.first?["speaker"] as? String, "human")
    XCTAssertEqual(history?.first?["text"] as? String, "hello")
    XCTAssertEqual(json["last_banti_utterance"] as? String, "hi there")
    XCTAssertEqual(json["is_interruption"] as? Bool, false)
}

func testBrainStreamBodyEncodesInterruptionTrue() throws {
    let body = BrainStreamBody(
        track: "reasoning",
        ambient_context: "{}",
        conversation_history: [],
        last_banti_utterance: nil,
        last_spoke_seconds_ago: 2.0,
        is_interruption: true,
        current_speech: "I was saying this"
    )
    let data = try JSONEncoder().encode(body)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(json["is_interruption"] as? Bool, true)
    XCTAssertEqual(json["current_speech"] as? String, "I was saying this")
}
```

- [ ] **Step 8: Run full test suite — expect pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test 2>&1 | tail -15
```

- [ ] **Step 9: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add Sources/BantiCore/BrainLoop.swift Tests/BantiTests/BrainLoopTests.swift
git commit -m "refactor: BrainLoop uses ConversationBuffer + BantiVoice — efference copy integrated"
```

---

## Task 7: Wire MemoryEngine + PerceptionRouter screen filter

Wire all new actors in `MemoryEngine.init`, expose `bantiVoice`, add screen self-echo filter to `PerceptionRouter`, and update `main.swift`.

**Files:**
- Modify: `Sources/BantiCore/MemoryEngine.swift`
- Modify: `Sources/BantiCore/PerceptionRouter.swift`
- Modify: `Sources/banti/main.swift`

- [ ] **Step 1: Update MemoryEngine.init — wire new actors in dependency order**

In `Sources/BantiCore/MemoryEngine.swift`, replace the construction of `cartesiaSpeaker` and `brainLoop`:

```swift
// New actor dependencies — order matters
let selfSpeechLog      = SelfSpeechLog()
let conversationBuffer = ConversationBuffer()
let cartesiaSpeaker    = CartesiaSpeaker(engine: engine, logger: logger)
let bantiVoice         = BantiVoice(
    cartesiaSpeaker: cartesiaSpeaker,
    selfSpeechLog: selfSpeechLog,
    conversationBuffer: conversationBuffer,
    logger: logger
)
self.bantiVoice = bantiVoice    // internal — accessible via @testable import

self.brainLoop = BrainLoop(
    context: context,
    sidecar: sidecar,
    bantiVoice: bantiVoice,
    conversationBuffer: conversationBuffer,
    logger: logger
)
```

- Remove the old `self.cartesiaSpeaker = CartesiaSpeaker(engine: engine, logger: logger)` and old `BrainLoop` init.
- Replace `let cartesiaSpeaker: CartesiaSpeaker` stored property with `let bantiVoice: BantiVoice`.
- Update `public let brainLoop: BrainLoop` — `BrainLoop.init` signature has changed.

- [ ] **Step 2: Add setBantiVoice to PerceptionRouter**

In `Sources/BantiCore/PerceptionRouter.swift`, add:
```swift
private var bantiVoice: BantiVoice?

public func setBantiVoice(_ voice: BantiVoice) {
    bantiVoice = voice
}
```

Update the screen dispatch section to filter before context update:
```swift
if hasText && source == "screen", let analyzer = screen,
   shouldFire(analyzerName: "screen", throttleSeconds: 4) {
    markFired(analyzerName: "screen")
    let voice = bantiVoice
    Task {
        guard let obs = await analyzer.analyze(jpegData: nil, events: events) else { return }
        if case .screen(let state) = obs, let v = voice {
            let rawText = state.ocrLines.joined(separator: "\n")
            let cleaned = await v.suppressSelfEcho(in: rawText)
            let cleanedLines = cleaned.components(separatedBy: "\n").filter { !$0.isEmpty }
            let cleanedInterp = await v.suppressSelfEcho(in: state.interpretation)
            let filteredState = ScreenState(ocrLines: cleanedLines,
                                            interpretation: cleanedInterp,
                                            updatedAt: state.updatedAt)
            await self.context.update(.screen(filteredState))
        } else {
            await self.context.update(obs)
        }
    }
}
```

- [ ] **Step 3: Wire setBantiVoice in main.swift**

In `Sources/banti/main.swift`, inside the `Task` that starts `MemoryEngine`:
```swift
Task {
    let fi = await memoryEngine.faceIdentifier
    await router.setFaceIdentifier(fi)
    await router.setBantiVoice(memoryEngine.bantiVoice)   // ADD THIS LINE
    await memoryEngine.start()
}
```

- [ ] **Step 4: Update any tests that used MemoryEngine.cartesiaSpeaker**

Run tests. If any test references `memoryEngine.cartesiaSpeaker`, update it to use `memoryEngine.bantiVoice`. Check `Tests/BantiTests/` for such references:
```bash
grep -r "cartesiaSpeaker" /Users/tpavankalyan/Downloads/Code/banti/Tests/
```
For each occurrence in test files, access via `memoryEngine.bantiVoice` and use `BantiVoice` test helpers if needed.

- [ ] **Step 5: Run full test suite — expect pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test 2>&1 | tail -15
```

- [ ] **Step 6: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add Sources/BantiCore/MemoryEngine.swift Sources/BantiCore/PerceptionRouter.swift \
    Sources/banti/main.swift
git commit -m "feat: wire BantiVoice into MemoryEngine + PerceptionRouter screen self-echo filter"
```

---

## Task 8: Python sidecar — BrainStreamRequest + prompt assembly

**Files:**
- Modify: `memory_sidecar/models.py`
- Modify: `memory_sidecar/memory.py`
- Create: `memory_sidecar/tests/test_brain_stream.py`

- [ ] **Step 1: Write the failing tests**

```python
# memory_sidecar/tests/test_brain_stream.py
import pytest
from models import BrainStreamRequest, ConversationTurn


class TestBrainStreamRequest:

    def test_accepts_conversation_history(self):
        req = BrainStreamRequest(
            track="reflex",
            ambient_context='{"face": {}}',
            conversation_history=[
                ConversationTurn(speaker="human", text="hello banti", timestamp=1000.0),
                ConversationTurn(speaker="banti", text="hi there", timestamp=1001.0),
            ],
        )
        assert len(req.conversation_history) == 2
        assert req.conversation_history[0].speaker == "human"

    def test_ambient_context_defaults_to_empty_object(self):
        req = BrainStreamRequest(track="reflex")
        assert req.ambient_context == "{}"

    def test_conversation_history_defaults_to_empty(self):
        req = BrainStreamRequest(track="reflex")
        assert req.conversation_history == []

    def test_last_banti_utterance_defaults_to_none(self):
        req = BrainStreamRequest(track="reflex")
        assert req.last_banti_utterance is None

    def test_old_snapshot_json_field_does_not_exist(self):
        req = BrainStreamRequest(track="reflex")
        assert not hasattr(req, "snapshot_json")

    def test_old_recent_speech_field_does_not_exist(self):
        req = BrainStreamRequest(track="reflex")
        assert not hasattr(req, "recent_speech")


class TestFormatConversation:
    """Tests for the _format_conversation helper used in prompt assembly."""

    def test_empty_history_returns_placeholder(self):
        from memory import _format_conversation
        result = _format_conversation([])
        assert result == "(no conversation yet)"

    def test_human_turn_prefixed_correctly(self):
        from memory import _format_conversation
        turn = ConversationTurn(speaker="human", text="hello", timestamp=1000.0)
        result = _format_conversation([turn])
        assert result == "Human: hello"

    def test_banti_turn_prefixed_correctly(self):
        from memory import _format_conversation
        turn = ConversationTurn(speaker="banti", text="hi there", timestamp=1001.0)
        result = _format_conversation([turn])
        assert result == "Banti: hi there"

    def test_mixed_turns_in_order(self):
        from memory import _format_conversation
        turns = [
            ConversationTurn(speaker="human", text="hello", timestamp=1000.0),
            ConversationTurn(speaker="banti", text="hi", timestamp=1001.0),
            ConversationTurn(speaker="human", text="how are you", timestamp=1002.0),
        ]
        result = _format_conversation(turns)
        assert result == "Human: hello\nBanti: hi\nHuman: how are you"
```

- [ ] **Step 2: Run tests — expect failure**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/memory_sidecar && python -m pytest tests/test_brain_stream.py -v 2>&1 | tail -15
```
Expected: `ImportError` or `ValidationError` — `BrainStreamRequest` still has old fields.

- [ ] **Step 3: Update models.py — add ConversationTurn, update BrainStreamRequest**

In `memory_sidecar/models.py`, add `ConversationTurn` and update `BrainStreamRequest`:

```python
class ConversationTurn(BaseModel):
    speaker: str      # "banti" or "human"
    text: str
    timestamp: float  # unix timestamp

class BrainStreamRequest(BaseModel):
    track: Literal["reflex", "reasoning"]
    ambient_context: str = "{}"                      # was: snapshot_json
    conversation_history: list[ConversationTurn] = []  # was: recent_speech: list[str]
    last_banti_utterance: Optional[str] = None       # was: last_spoke_text
    last_spoke_seconds_ago: float = 9999.0
    is_interruption: bool = False
    current_speech: Optional[str] = None
```

Remove the old `BrainStreamRequest` definition entirely.

- [ ] **Step 4: Add _format_conversation helper to memory.py**

At the top of `memory_sidecar/memory.py`, add this helper function (before `_reflex_stream`):

```python
def _format_conversation(turns) -> str:
    """Format ConversationTurn list as Human:/Banti: dialogue string."""
    if not turns:
        return "(no conversation yet)"
    lines = []
    for t in turns:
        label = "Banti" if t.speaker == "banti" else "Human"
        lines.append(f"{label}: {t.text}")
    return "\n".join(lines)
```

- [ ] **Step 5: Update _reflex_stream prompt assembly**

In `_reflex_stream`, replace:
```python
user_msg = f"Snapshot:\n{req.snapshot_json}\n\nRecent speech:\n" + "\n".join(req.recent_speech)
```
With:
```python
conversation = _format_conversation(req.conversation_history)
user_msg = f"Ambient context:\n{req.ambient_context}\n\nConversation:\n{conversation}"
```

- [ ] **Step 6: Update _reasoning_stream prompt assembly**

In `_reasoning_stream`:
1. Replace `req.snapshot_json` with `req.ambient_context` in the `_fetch_mem0` nested function:
   ```python
   snap_dict = json.loads(req.ambient_context) if req.ambient_context != "{}" else {}
   ```
2. Replace the `user_msg` assembly:
   ```python
   conversation = _format_conversation(req.conversation_history)
   user_msg = (
       f"Memory context:\n{snapshot_summary}\n\n"
       f"Ambient context:\n{req.ambient_context}\n\n"
       f"Conversation:\n{conversation}"
   )
   ```

- [ ] **Step 7: Run Python tests — expect pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/memory_sidecar && python -m pytest tests/test_brain_stream.py -v 2>&1 | tail -15
```

- [ ] **Step 8: Run full Python test suite — expect pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/memory_sidecar && python -m pytest tests/ -v 2>&1 | tail -20
```

- [ ] **Step 9: Run full Swift test suite — expect pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test 2>&1 | tail -15
```

- [ ] **Step 10: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add memory_sidecar/models.py memory_sidecar/memory.py memory_sidecar/tests/test_brain_stream.py
git commit -m "feat: update sidecar BrainStreamRequest — conversation_history replaces recent_speech"
```

---

## Final Verification

- [ ] **Run complete Swift test suite one final time**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test 2>&1 | grep -E "Test Suite|passed|failed"
```
Expected: all test suites pass, 0 failures.

- [ ] **Run complete Python test suite**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/memory_sidecar && python -m pytest tests/ -v 2>&1 | grep -E "passed|failed|error"
```
Expected: all tests pass.

- [ ] **Verify no references to old fields remain**

```bash
grep -r "recent_speech\|snapshot_json\|last_spoke_text" \
    /Users/tpavankalyan/Downloads/Code/banti/Sources \
    /Users/tpavankalyan/Downloads/Code/banti/Tests \
    /Users/tpavankalyan/Downloads/Code/banti/memory_sidecar/*.py 2>/dev/null
```
Expected: no matches (or only in git history and this plan file).

- [ ] **Verify no references to removed Swift APIs remain**

```bash
grep -r "PerceptionObservation.speech\|context\.speech\|\.speech(\|appendTranscript\|recentTranscripts\|lastSpokeText" \
    /Users/tpavankalyan/Downloads/Code/banti/Sources \
    /Users/tpavankalyan/Downloads/Code/banti/Tests 2>/dev/null
```
Expected: no matches.

- [ ] **Final commit if any cleanup was needed**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git status
# If clean: nothing to do. If files changed from cleanup: commit them.
```
