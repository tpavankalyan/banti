# Mic ASR + Speaker Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS SwiftUI app that continuously captures microphone audio, streams to Deepgram for real-time ASR with speaker diarization, and displays a live transcript — all on an actor-mesh architecture.

**Architecture:** Each perception module is a Swift actor conforming to `PerceptionModule`. Modules communicate via typed events on `EventHubActor` (with bounded per-subscriber queues for backpressure). `ModuleSupervisorActor` manages lifecycle, health polling, and restart policies. Audio bridging uses an `@unchecked Sendable` ring buffer class drained by a cooperative task.

**Tech Stack:** Swift 5.9+, macOS 14+, SwiftUI, AVFoundation, URLSessionWebSocketTask, os.log. Zero third-party runtime dependencies.

**Build prerequisite:** XcodeGen (`brew install xcodegen`) is used to generate the `.xcodeproj` from `project.yml`.

**Spec:** `docs/superpowers/specs/2026-03-20-mic-asr-diarization-design.md`

---

## File Map

```
Banti/
├── Banti/
│   ├── BantiApp.swift
│   ├── Info.plist
│   ├── Banti.entitlements
│   ├── Config/
│   │   ├── ConfigActor.swift
│   │   └── Environment.swift
│   ├── Core/
│   │   ├── PerceptionModule.swift
│   │   ├── PerceptionEvent.swift
│   │   ├── EventHubActor.swift
│   │   ├── ModuleSupervisorActor.swift
│   │   ├── StateRegistryActor.swift
│   │   ├── AudioRingBuffer.swift
│   │   └── Events/
│   │       ├── AudioFrameEvent.swift
│   │       ├── RawTranscriptEvent.swift
│   │       ├── TranscriptSegmentEvent.swift
│   │       └── ModuleStatusEvent.swift
│   ├── Modules/
│   │   └── Microphone/
│   │       ├── MicrophoneCaptureActor.swift
│   │       ├── DeepgramStreamingActor.swift
│   │       └── TranscriptProjectionActor.swift
│   └── UI/
│       ├── TranscriptViewModel.swift
│       └── TranscriptView.swift
├── BantiTests/
│   ├── EventHubActorTests.swift
│   ├── ConfigActorTests.swift
│   ├── StateRegistryActorTests.swift
│   ├── ModuleSupervisorActorTests.swift
│   ├── TranscriptProjectionActorTests.swift
│   ├── DeepgramParsingTests.swift
│   └── Helpers/
│       └── MockPerceptionModule.swift
└── project.yml
```

---

### Task 1: Project Scaffold + Core Types

**Files:**
- Create: `Banti/project.yml`
- Create: `Banti/Banti/Info.plist`
- Create: `Banti/Banti/Banti.entitlements`
- Create: `Banti/Banti/Core/PerceptionModule.swift`
- Create: `Banti/Banti/Core/PerceptionEvent.swift`
- Create: `Banti/Banti/BantiApp.swift` (stub)

- [ ] **Step 1: Create project.yml for XcodeGen**

```yaml
name: Banti
options:
  bundleIdPrefix: com.banti
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "15.0"
settings:
  SWIFT_VERSION: "5.9"
  SWIFT_STRICT_CONCURRENCY: complete
targets:
  Banti:
    type: application
    platform: macOS
    sources:
      - Banti
    entitlements:
      path: Banti/Banti.entitlements
    info:
      path: Banti/Info.plist
  BantiTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - BantiTests
    dependencies:
      - target: Banti
    settings:
      TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Banti.app/Contents/MacOS/Banti"
      BUNDLE_LOADER: "$(TEST_HOST)"
```

- [ ] **Step 2: Create Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>Banti needs microphone access for continuous speech transcription.</string>
</dict>
</plist>
```

- [ ] **Step 3: Create entitlements**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 4: Write PerceptionModule.swift**

```swift
import Foundation

struct ModuleID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    var description: String { rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

struct Capability: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }

    static let audioCapture = Capability("audio-capture")
    static let transcription = Capability("transcription")
    static let diarization = Capability("diarization")
    static let projection = Capability("projection")
}

enum ModuleHealth: Sendable {
    case healthy
    case degraded(reason: String)
    case failed(error: any Error)

    var label: String {
        switch self {
        case .healthy: "healthy"
        case .degraded(let r): "degraded:\(r)"
        case .failed: "failed"
        }
    }
}

enum RestartPolicy: Sendable {
    case never
    case onFailure(maxRetries: Int, backoff: TimeInterval)
    case always
}

protocol PerceptionModule: Actor {
    var id: ModuleID { get }
    var capabilities: Set<Capability> { get }
    func start() async throws
    func stop() async
    func health() async -> ModuleHealth
}
```

- [ ] **Step 5: Write PerceptionEvent.swift**

```swift
import Foundation

struct SubscriptionID: Hashable, Sendable {
    let rawValue: UUID
    init() { self.rawValue = UUID() }
}

protocol PerceptionEvent: Sendable {
    var id: UUID { get }
    var timestamp: Date { get }
    var sourceModule: ModuleID { get }
}
```

- [ ] **Step 6: Write BantiApp.swift stub**

```swift
import SwiftUI

@main
struct BantiApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Banti — loading...")
        }
    }
}
```

- [ ] **Step 7: Install XcodeGen if needed, generate project, build**

```bash
which xcodegen || brew install xcodegen
cd Banti && xcodegen generate
xcodebuild -project Banti.xcodeproj -scheme Banti -destination 'platform=macOS' build
```

- [ ] **Step 8: Commit**

```bash
git add Banti/
git commit -m "feat: project scaffold with core PerceptionModule and PerceptionEvent types"
```

---

### Task 2: EventHubActor (with real backpressure)

**Files:**
- Create: `Banti/Banti/Core/EventHubActor.swift`
- Create: `Banti/BantiTests/EventHubActorTests.swift`

- [ ] **Step 1: Write EventHubActor tests**

```swift
import XCTest
@testable import Banti

struct TestEvent: PerceptionEvent {
    let id = UUID()
    let timestamp = Date()
    let sourceModule = ModuleID("test")
    let value: String
}

final class EventHubActorTests: XCTestCase {
    func testPublishDeliversToSubscriber() async {
        let hub = EventHubActor()
        let expectation = XCTestExpectation(description: "received event")
        var received: String?

        _ = await hub.subscribe(TestEvent.self) { event in
            received = event.value
            expectation.fulfill()
        }

        await hub.publish(TestEvent(value: "hello"))
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(received, "hello")
    }

    func testUnsubscribeStopsDelivery() async {
        let hub = EventHubActor()
        let exp = XCTestExpectation(description: "first event")
        var count = 0

        let subID = await hub.subscribe(TestEvent.self) { _ in
            count += 1
            exp.fulfill()
        }

        await hub.publish(TestEvent(value: "a"))
        await fulfillment(of: [exp], timeout: 2)

        await hub.unsubscribe(subID)
        await hub.publish(TestEvent(value: "b"))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(count, 1)
    }

    func testMultipleSubscribersReceive() async {
        let hub = EventHubActor()
        let exp1 = XCTestExpectation(description: "sub1")
        let exp2 = XCTestExpectation(description: "sub2")

        _ = await hub.subscribe(TestEvent.self) { _ in exp1.fulfill() }
        _ = await hub.subscribe(TestEvent.self) { _ in exp2.fulfill() }

        await hub.publish(TestEvent(value: "x"))
        await fulfillment(of: [exp1, exp2], timeout: 2)
    }

    func testBackpressureDropsOldest() async {
        let hub = EventHubActor(maxQueueSize: 3)
        var received: [String] = []
        let exp = XCTestExpectation(description: "done")
        exp.expectedFulfillmentCount = 3

        _ = await hub.subscribe(TestEvent.self) { event in
            try? await Task.sleep(for: .milliseconds(100))
            received.append(event.value)
            exp.fulfill()
        }

        for i in 0..<6 {
            await hub.publish(TestEvent(value: "\(i)"))
        }

        await fulfillment(of: [exp], timeout: 5)
        XCTAssertEqual(received.count, 3)
        // Under backpressure, oldest are dropped so we get the latest events
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Banti.xcodeproj -scheme BantiTests -destination 'platform=macOS'
```
Expected: FAIL — `EventHubActor` not defined

- [ ] **Step 3: Implement EventHubActor with bounded per-subscriber queues**

```swift
import Foundation
import os

actor EventHubActor {
    private let logger = Logger(subsystem: "com.banti.core", category: "EventHub")
    private let maxQueueSize: Int

    private struct Subscription {
        let queue: BoundedEventQueue
    }

    private var subscriptions: [ObjectIdentifier: [SubscriptionID: Subscription]] = [:]

    init(maxQueueSize: Int = 500) {
        self.maxQueueSize = maxQueueSize
    }

    func publish<E: PerceptionEvent>(_ event: E) async {
        let typeKey = ObjectIdentifier(E.self)
        guard let subs = subscriptions[typeKey] else { return }
        for (_, sub) in subs {
            sub.queue.enqueue(event)
        }
    }

    @discardableResult
    func subscribe<E: PerceptionEvent>(
        _ type: E.Type,
        handler: @escaping @Sendable (E) async -> Void
    ) -> SubscriptionID {
        let subID = SubscriptionID()
        let typeKey = ObjectIdentifier(E.self)
        let queue = BoundedEventQueue(maxSize: maxQueueSize)
        let sub = Subscription(queue: queue)

        if subscriptions[typeKey] == nil {
            subscriptions[typeKey] = [:]
        }
        subscriptions[typeKey]?[subID] = sub

        Task { [weak self] in
            for await event in queue.stream {
                guard self != nil else { break }
                if let typed = event as? E {
                    await handler(typed)
                }
            }
        }

        return subID
    }

    func unsubscribe(_ id: SubscriptionID) {
        for typeKey in subscriptions.keys {
            if let sub = subscriptions[typeKey]?[id] {
                sub.queue.finish()
                subscriptions[typeKey]?.removeValue(forKey: id)
            }
        }
    }
}

final class BoundedEventQueue: @unchecked Sendable {
    private var continuation: AsyncStream<any PerceptionEvent>.Continuation?
    let stream: AsyncStream<any PerceptionEvent>

    init(maxSize: Int) {
        var cont: AsyncStream<any PerceptionEvent>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(maxSize)) { cont = $0 }
        self.continuation = cont
    }

    func enqueue(_ event: any PerceptionEvent) {
        continuation?.yield(event)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: EventHubActor with AsyncStream-backed per-subscriber queues"
```

---

### Task 3: ConfigActor

**Files:**
- Create: `Banti/Banti/Config/ConfigActor.swift`
- Create: `Banti/Banti/Config/Environment.swift`
- Create: `Banti/BantiTests/ConfigActorTests.swift`

- [ ] **Step 1: Write ConfigActor tests**

```swift
import XCTest
@testable import Banti

final class ConfigActorTests: XCTestCase {
    func testParsesExportSyntax() async {
        let content = "export DEEPGRAM_API_KEY=abc123\nexport OTHER_KEY=def456"
        let config = ConfigActor(content: content)
        let val = await config.value(for: "DEEPGRAM_API_KEY")
        XCTAssertEqual(val, "abc123")
    }

    func testParsesPlainSyntax() async {
        let config = ConfigActor(content: "MY_KEY=value")
        let val = await config.value(for: "MY_KEY")
        XCTAssertEqual(val, "value")
    }

    func testIgnoresCommentsAndBlanks() async {
        let content = "# comment\n\nexport KEY=val"
        let config = ConfigActor(content: content)
        let val = await config.value(for: "KEY")
        XCTAssertEqual(val, "val")
        let missing = await config.value(for: "# comment")
        XCTAssertNil(missing)
    }

    func testRequireThrowsOnMissing() async {
        let config = ConfigActor(content: "A=1")
        do {
            _ = try await config.require("MISSING")
            XCTFail("Should throw")
        } catch {}
    }

    func testValueContainingEquals() async {
        let config = ConfigActor(content: "KEY=a=b=c")
        let val = await config.value(for: "KEY")
        XCTAssertEqual(val, "a=b=c")
    }
}
```

- [ ] **Step 2: Run tests, verify fail**

- [ ] **Step 3: Implement ConfigActor and Environment**

ConfigActor.swift:
```swift
import Foundation

struct ConfigError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

actor ConfigActor {
    private let values: [String: String]

    init(content: String) {
        self.values = Self.parse(content)
    }

    init(envFilePath: String) {
        if let content = try? String(contentsOfFile: envFilePath, encoding: .utf8) {
            self.values = Self.parse(content)
        } else {
            self.values = [:]
        }
    }

    private nonisolated static func parse(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            var keyValue = trimmed
            if keyValue.hasPrefix("export ") {
                keyValue = String(keyValue.dropFirst(7))
            }
            guard let eqIndex = keyValue.firstIndex(of: "=") else { continue }
            let key = String(keyValue[keyValue.startIndex..<eqIndex])
                .trimmingCharacters(in: .whitespaces)
            let value = String(keyValue[keyValue.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    func value(for key: String) -> String? {
        values[key]
    }

    func require(_ key: String) throws -> String {
        guard let val = values[key] else {
            throw ConfigError(message: "Missing required config key: \(key)")
        }
        return val
    }
}
```

Environment.swift:
```swift
import Foundation

enum EnvKey {
    static let deepgramAPIKey = "DEEPGRAM_API_KEY"
    static let deepgramModel = "DEEPGRAM_MODEL"
    static let deepgramLanguage = "DEEPGRAM_LANGUAGE"
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: ConfigActor with nonisolated .env parser"
```

---

### Task 4: StateRegistryActor

**Files:**
- Create: `Banti/Banti/Core/StateRegistryActor.swift`
- Create: `Banti/BantiTests/StateRegistryActorTests.swift`

- [ ] **Step 1: Write StateRegistryActor tests**

```swift
import XCTest
@testable import Banti

final class StateRegistryActorTests: XCTestCase {
    func testUpdateAndRetrieveStatus() async {
        let registry = StateRegistryActor()
        let mid = ModuleID("test")
        await registry.update(mid, status: .healthy)
        let status = await registry.status(for: mid)
        XCTAssertEqual(status?.label, "healthy")
    }

    func testAllStatusesReturnsAll() async {
        let registry = StateRegistryActor()
        await registry.update(ModuleID("a"), status: .healthy)
        await registry.update(ModuleID("b"), status: .degraded(reason: "slow"))
        let all = await registry.allStatuses()
        XCTAssertEqual(all.count, 2)
    }

    func testLastErrorTracked() async {
        let registry = StateRegistryActor()
        let mid = ModuleID("err")
        let err = ConfigError(message: "boom")
        await registry.update(mid, status: .failed(error: err))
        let lastErr = await registry.lastError(for: mid)
        XCTAssertNotNil(lastErr)
    }

    func testMissingModuleReturnsNil() async {
        let registry = StateRegistryActor()
        let status = await registry.status(for: ModuleID("nonexistent"))
        XCTAssertNil(status)
    }
}
```

- [ ] **Step 2: Run tests, verify fail**

- [ ] **Step 3: Implement StateRegistryActor**

```swift
import Foundation
import os

actor StateRegistryActor {
    private let logger = Logger(subsystem: "com.banti.core", category: "StateRegistry")
    private var statuses: [ModuleID: ModuleHealth] = [:]
    private var errors: [ModuleID: any Error] = [:]

    func update(_ moduleID: ModuleID, status: ModuleHealth) {
        statuses[moduleID] = status
        if case .failed(let error) = status {
            errors[moduleID] = error
        }
    }

    func status(for moduleID: ModuleID) -> ModuleHealth? {
        statuses[moduleID]
    }

    func allStatuses() -> [ModuleID: ModuleHealth] {
        statuses
    }

    func lastError(for moduleID: ModuleID) -> (any Error)? {
        errors[moduleID]
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: StateRegistryActor with tests"
```

---

### Task 5: Event Types

**Files:**
- Create: `Banti/Banti/Core/Events/AudioFrameEvent.swift`
- Create: `Banti/Banti/Core/Events/RawTranscriptEvent.swift`
- Create: `Banti/Banti/Core/Events/TranscriptSegmentEvent.swift`
- Create: `Banti/Banti/Core/Events/ModuleStatusEvent.swift`

- [ ] **Step 1: Write all four event types**

AudioFrameEvent.swift:
```swift
import Foundation

struct AudioFrameEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let audioData: Data
    let sequenceNumber: UInt64
    let sampleRate: Int

    init(audioData: Data, sequenceNumber: UInt64, sampleRate: Int = 16000) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("mic-capture")
        self.audioData = audioData
        self.sequenceNumber = sequenceNumber
        self.sampleRate = sampleRate
    }
}
```

RawTranscriptEvent.swift:
```swift
import Foundation

struct RawTranscriptEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String
    let speakerIndex: Int?
    let confidence: Double
    let isFinal: Bool
    let audioStartTime: TimeInterval
    let audioEndTime: TimeInterval

    init(text: String, speakerIndex: Int?, confidence: Double,
         isFinal: Bool, audioStartTime: TimeInterval, audioEndTime: TimeInterval) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("deepgram-asr")
        self.text = text
        self.speakerIndex = speakerIndex
        self.confidence = confidence
        self.isFinal = isFinal
        self.audioStartTime = audioStartTime
        self.audioEndTime = audioEndTime
    }
}
```

TranscriptSegmentEvent.swift:
```swift
import Foundation

struct TranscriptSegmentEvent: PerceptionEvent, Identifiable {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let speakerLabel: String
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let isFinal: Bool

    init(speakerLabel: String, text: String,
         startTime: TimeInterval, endTime: TimeInterval, isFinal: Bool) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("transcript-projection")
        self.speakerLabel = speakerLabel
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.isFinal = isFinal
    }
}
```

ModuleStatusEvent.swift:
```swift
import Foundation

struct ModuleStatusEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let moduleID: ModuleID
    let oldStatus: String
    let newStatus: String

    init(moduleID: ModuleID, oldStatus: String, newStatus: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("supervisor")
        self.moduleID = moduleID
        self.oldStatus = oldStatus
        self.newStatus = newStatus
    }
}
```

- [ ] **Step 2: Build to verify compilation**

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: event contracts — AudioFrame, RawTranscript, TranscriptSegment, ModuleStatus"
```

---

### Task 6: ModuleSupervisorActor

**Files:**
- Create: `Banti/Banti/Core/ModuleSupervisorActor.swift`
- Create: `Banti/BantiTests/Helpers/MockPerceptionModule.swift`
- Create: `Banti/BantiTests/ModuleSupervisorActorTests.swift`

- [ ] **Step 1: Write MockPerceptionModule helper**

```swift
import Foundation
@testable import Banti

actor MockPerceptionModule: PerceptionModule {
    let id: ModuleID
    let capabilities: Set<Capability>
    var started = false
    var stopped = false
    var shouldFail = false
    var startOrder: Int = 0
    private var _health: ModuleHealth = .healthy

    nonisolated(unsafe) static var globalStartCounter = 0

    static func resetCounter() { globalStartCounter = 0 }

    init(id: String, shouldFail: Bool = false) {
        self.id = ModuleID(id)
        self.capabilities = [Capability("mock")]
        self.shouldFail = shouldFail
    }

    func start() async throws {
        if shouldFail { throw ConfigError(message: "mock failure") }
        MockPerceptionModule.globalStartCounter += 1
        startOrder = MockPerceptionModule.globalStartCounter
        started = true
    }

    func stop() async {
        stopped = true
        started = false
    }

    func health() async -> ModuleHealth { _health }

    func setHealth(_ h: ModuleHealth) { _health = h }
}
```

- [ ] **Step 2: Write ModuleSupervisorActor tests**

```swift
import XCTest
@testable import Banti

final class ModuleSupervisorActorTests: XCTestCase {
    override func setUp() async throws {
        await MockPerceptionModule.resetCounter()
    }

    func testStartAllStartsRegisteredModules() async throws {
        let hub = EventHubActor()
        let registry = StateRegistryActor()
        let supervisor = ModuleSupervisorActor(eventHub: hub, stateRegistry: registry)
        let modA = MockPerceptionModule(id: "a")
        let modB = MockPerceptionModule(id: "b")

        await supervisor.register(modA, restartPolicy: .never)
        await supervisor.register(modB, restartPolicy: .never)
        try await supervisor.startAll()

        let aStarted = await modA.started
        let bStarted = await modB.started
        XCTAssertTrue(aStarted)
        XCTAssertTrue(bStarted)
    }

    func testStopAllStopsInReverseOrder() async throws {
        let hub = EventHubActor()
        let registry = StateRegistryActor()
        let supervisor = ModuleSupervisorActor(eventHub: hub, stateRegistry: registry)
        let mod = MockPerceptionModule(id: "a")

        await supervisor.register(mod, restartPolicy: .never)
        try await supervisor.startAll()
        await supervisor.stopAll()

        let stopped = await mod.stopped
        XCTAssertTrue(stopped)
    }

    func testStartAllRollsBackOnFailure() async throws {
        let hub = EventHubActor()
        let registry = StateRegistryActor()
        let supervisor = ModuleSupervisorActor(eventHub: hub, stateRegistry: registry)
        let goodMod = MockPerceptionModule(id: "good")
        let badMod = MockPerceptionModule(id: "bad", shouldFail: true)

        await supervisor.register(goodMod, restartPolicy: .never)
        await supervisor.register(badMod, restartPolicy: .never,
                                  dependencies: [ModuleID("good")])

        do {
            try await supervisor.startAll()
            XCTFail("Should have thrown")
        } catch {}

        let goodStopped = await goodMod.stopped
        XCTAssertTrue(goodStopped, "Previously started module should be rolled back")
    }

    func testRestartModule() async throws {
        let hub = EventHubActor()
        let registry = StateRegistryActor()
        let supervisor = ModuleSupervisorActor(eventHub: hub, stateRegistry: registry)
        let mod = MockPerceptionModule(id: "a")

        await supervisor.register(mod, restartPolicy: .never)
        try await supervisor.startAll()
        try await supervisor.restart(ModuleID("a"))

        let started = await mod.started
        XCTAssertTrue(started)
    }
}
```

- [ ] **Step 3: Run tests, verify fail**

- [ ] **Step 4: Implement ModuleSupervisorActor**

```swift
import Foundation
import os

actor ModuleSupervisorActor {
    private let logger = Logger(subsystem: "com.banti.core", category: "Supervisor")
    private let eventHub: EventHubActor
    private let stateRegistry: StateRegistryActor

    private struct ModuleEntry: Sendable {
        let module: any PerceptionModule
        let restartPolicy: RestartPolicy
        let dependencies: Set<ModuleID>
    }

    private var modules: [ModuleID: ModuleEntry] = [:]
    private var startOrder: [ModuleID] = []
    private var healthTask: Task<Void, Never>?

    init(eventHub: EventHubActor, stateRegistry: StateRegistryActor) {
        self.eventHub = eventHub
        self.stateRegistry = stateRegistry
    }

    func register(
        _ module: any PerceptionModule,
        restartPolicy: RestartPolicy,
        dependencies: Set<ModuleID> = []
    ) {
        let entry = ModuleEntry(
            module: module,
            restartPolicy: restartPolicy,
            dependencies: dependencies
        )
        modules[module.id] = entry
    }

    func startAll() async throws {
        let sorted = topologicalSort()
        for moduleID in sorted {
            guard let entry = modules[moduleID] else { continue }
            do {
                try await entry.module.start()
                await stateRegistry.update(moduleID, status: .healthy)
                startOrder.append(moduleID)
                logger.info("Started module: \(moduleID.rawValue)")
            } catch {
                await stateRegistry.update(moduleID, status: .failed(error: error))
                logger.error("Failed to start \(moduleID.rawValue): \(error.localizedDescription)")
                for started in startOrder.reversed() {
                    if let m = modules[started] {
                        await m.module.stop()
                    }
                }
                startOrder.removeAll()
                throw error
            }
        }
        startHealthPolling()
    }

    func stopAll() async {
        healthTask?.cancel()
        healthTask = nil
        for moduleID in startOrder.reversed() {
            if let entry = modules[moduleID] {
                await entry.module.stop()
                logger.info("Stopped module: \(moduleID.rawValue)")
            }
        }
        startOrder.removeAll()
    }

    func restart(_ moduleID: ModuleID) async throws {
        guard let entry = modules[moduleID] else { return }
        await entry.module.stop()
        try await entry.module.start()
        await stateRegistry.update(moduleID, status: .healthy)
    }

    private func startHealthPolling() {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.pollHealth()
            }
        }
    }

    private func pollHealth() async {
        for (moduleID, entry) in modules {
            let health = await entry.module.health()
            let oldHealth = await stateRegistry.status(for: moduleID)
            let oldStr = oldHealth?.label ?? "unknown"
            let newStr = health.label
            if oldStr != newStr {
                await stateRegistry.update(moduleID, status: health)
                await eventHub.publish(ModuleStatusEvent(
                    moduleID: moduleID,
                    oldStatus: oldStr,
                    newStatus: newStr
                ))
            }
        }
    }

    private func topologicalSort() -> [ModuleID] {
        var visited = Set<ModuleID>()
        var result: [ModuleID] = []
        func visit(_ id: ModuleID) {
            guard !visited.contains(id) else { return }
            visited.insert(id)
            if let entry = modules[id] {
                for dep in entry.dependencies { visit(dep) }
            }
            result.append(id)
        }
        for id in modules.keys { visit(id) }
        return result
    }
}
```

- [ ] **Step 5: Run tests, verify pass**

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: ModuleSupervisorActor with lifecycle, rollback, health polling"
```

---

### Task 7: AudioRingBuffer + MicrophoneCaptureActor

**Files:**
- Create: `Banti/Banti/Core/AudioRingBuffer.swift`
- Create: `Banti/Banti/Modules/Microphone/MicrophoneCaptureActor.swift`

- [ ] **Step 1: Implement AudioRingBuffer (@unchecked Sendable)**

This is the real-time-safe bridge between AVAudioEngine's audio thread and Swift concurrency. Uses `NSLock` (which avoids priority inversion on Darwin).

```swift
import Foundation

final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        frames.append(data)
        lock.unlock()
    }

    func drain() -> [Data] {
        lock.lock()
        let result = frames
        frames.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }
}
```

- [ ] **Step 2: Implement MicrophoneCaptureActor**

The tap callback writes into the `AudioRingBuffer` (safe from audio thread). A drain `Task` reads it every ~50ms and publishes events.

```swift
import Foundation
import AVFoundation
import os

protocol AudioFrameReplayProvider: Actor {
    func replayFrames(after lastSeq: UInt64) async -> [(seq: UInt64, data: Data)]
}

actor MicrophoneCaptureActor: PerceptionModule, AudioFrameReplayProvider {
    let id = ModuleID("mic-capture")
    let capabilities: Set<Capability> = [.audioCapture]

    private let logger = Logger(subsystem: "com.banti.mic-capture", category: "Capture")
    private let eventHub: EventHubActor
    private let sampleRate: Double = 16000
    private let bufferDuration: TimeInterval = 0.1

    private var audioEngine: AVAudioEngine?
    private var drainTask: Task<Void, Never>?
    private var sequenceNumber: UInt64 = 0
    private let bridgeBuffer = AudioRingBuffer()
    private var _health: ModuleHealth = .healthy

    private var replayBuffer: [(seq: UInt64, data: Data)] = []
    private let maxReplayFrames = 100

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    func start() async throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            _health = .failed(error: ConfigError(message: "No audio input available"))
            throw ConfigError(message: "No audio input available")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw ConfigError(message: "Cannot create target audio format")
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw ConfigError(message: "Cannot create audio converter")
        }

        let bufferSize = AVAudioFrameCount(sampleRate * bufferDuration)
        let bridge = self.bridgeBuffer

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) {
            buffer, _ in
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: bufferSize
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else { return }

            let frameLength = Int(convertedBuffer.frameLength)
            guard frameLength > 0,
                  let channelData = convertedBuffer.int16ChannelData else { return }
            let data = Data(bytes: channelData[0], count: frameLength * 2)

            bridge.append(data)
        }

        try engine.start()
        self.audioEngine = engine
        _health = .healthy
        logger.info("Audio engine started at \(self.sampleRate)Hz")

        startDrainTask()
    }

    func stop() async {
        drainTask?.cancel()
        drainTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        logger.info("Audio engine stopped")
    }

    func health() -> ModuleHealth { _health }

    func replayFrames(after lastSeq: UInt64) -> [(seq: UInt64, data: Data)] {
        replayBuffer.filter { $0.seq > lastSeq }
    }

    private func startDrainTask() {
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                await self.drainPendingFrames()
            }
        }
    }

    private func drainPendingFrames() async {
        let frames = bridgeBuffer.drain()
        for frame in frames {
            sequenceNumber += 1
            let event = AudioFrameEvent(
                audioData: frame,
                sequenceNumber: sequenceNumber,
                sampleRate: Int(sampleRate)
            )
            replayBuffer.append((seq: sequenceNumber, data: frame))
            if replayBuffer.count > maxReplayFrames {
                replayBuffer.removeFirst()
            }
            await eventHub.publish(event)
        }
    }
}
```

- [ ] **Step 3: Build to verify compilation**

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: AudioRingBuffer + MicrophoneCaptureActor with Sendable bridge"
```

---

### Task 8: DeepgramStreamingActor (with replay + error rate tracking)

**Files:**
- Create: `Banti/Banti/Modules/Microphone/DeepgramStreamingActor.swift`
- Create: `Banti/BantiTests/DeepgramParsingTests.swift`

- [ ] **Step 1: Write Deepgram JSON parsing tests**

```swift
import XCTest
@testable import Banti

final class DeepgramParsingTests: XCTestCase {
    func testDecodesFullResponseWithWords() throws {
        let json = """
        {
            "channel": {
                "alternatives": [{
                    "transcript": "hello world",
                    "confidence": 0.95,
                    "words": [
                        {"word": "hello", "start": 0.0, "end": 0.5,
                         "confidence": 0.97, "speaker": 0, "punctuated_word": "Hello"},
                        {"word": "world", "start": 0.5, "end": 1.0,
                         "confidence": 0.93, "speaker": 0, "punctuated_word": "world."}
                    ]
                }]
            },
            "is_final": true,
            "start": 0.0,
            "duration": 1.0
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        XCTAssertTrue(response.isFinal ?? false)
        XCTAssertEqual(response.channel?.alternatives?.first?.words?.count, 2)
        XCTAssertEqual(response.channel?.alternatives?.first?.words?[0].speaker, 0)
        XCTAssertEqual(response.channel?.alternatives?.first?.words?[0].punctuatedWord, "Hello")
    }

    func testDecodesResponseWithoutWords() throws {
        let json = """
        {
            "channel": {
                "alternatives": [{
                    "transcript": "hello",
                    "confidence": 0.9
                }]
            },
            "is_final": false,
            "start": 0.0,
            "duration": 0.5
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        XCTAssertFalse(response.isFinal ?? true)
        XCTAssertNil(response.channel?.alternatives?.first?.words)
        XCTAssertEqual(response.channel?.alternatives?.first?.transcript, "hello")
    }

    func testDecodesMinimalResponse() throws {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        XCTAssertNil(response.channel)
    }
}
```

- [ ] **Step 2: Run tests, verify fail**

- [ ] **Step 3: Implement DeepgramStreamingActor**

```swift
import Foundation
import os

actor DeepgramStreamingActor: PerceptionModule {
    let id = ModuleID("deepgram-asr")
    let capabilities: Set<Capability> = [.transcription, .diarization]

    private let logger = Logger(subsystem: "com.banti.deepgram-asr", category: "Deepgram")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let replayProvider: (any AudioFrameReplayProvider)?
    private var webSocketTask: URLSessionWebSocketTask?
    private var subscriptionID: SubscriptionID?
    private var receiveTask: Task<Void, Never>?
    private var _health: ModuleHealth = .healthy
    private var lastSentSequence: UInt64 = 0
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelays: [TimeInterval] = [1, 2, 4, 8, 16]

    // Error rate tracking: sliding window
    private var parseErrors: [Date] = []
    private var parseTimes: [Date] = []
    private let errorWindowSeconds: TimeInterval = 30
    private let errorRateThreshold: Double = 0.10
    private var isReconnecting = false

    init(eventHub: EventHubActor, config: ConfigActor,
         replayProvider: (any AudioFrameReplayProvider)? = nil) {
        self.eventHub = eventHub
        self.config = config
        self.replayProvider = replayProvider
    }

    func start() async throws {
        let apiKey = try await config.require(EnvKey.deepgramAPIKey)
        try await connect(apiKey: apiKey)

        subscriptionID = await eventHub.subscribe(AudioFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.sendAudio(event)
        }
    }

    func stop() async {
        if let subID = subscriptionID {
            await eventHub.unsubscribe(subID)
            subscriptionID = nil
        }
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    func health() -> ModuleHealth { _health }

    private func connect(apiKey: String) async throws {
        let model = (await config.value(for: EnvKey.deepgramModel)) ?? "nova-2"
        let language = (await config.value(for: EnvKey.deepgramLanguage)) ?? "en"

        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()
        self.webSocketTask = task
        _health = .healthy
        reconnectAttempts = 0
        logger.info("Connected to Deepgram (model=\(model), lang=\(language))")

        startReceiving()
    }

    private func sendAudio(_ event: AudioFrameEvent) {
        guard let ws = webSocketTask else { return }
        lastSentSequence = event.sequenceNumber
        let message = URLSessionWebSocketTask.Message.data(event.audioData)
        ws.send(message) { [weak self] error in
            if let error {
                Task { [weak self] in
                    guard let self else { return }
                    await self.handleSendError(error)
                }
            }
        }
    }

    private func handleSendError(_ error: Error) {
        logger.error("WebSocket send error: \(error.localizedDescription)")
        _health = .degraded(reason: "send error")
        Task { [weak self] in await self?.attemptReconnect() }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let ws = await self.webSocketTask else { return }
                do {
                    let message = try await ws.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        await self?.handleReceiveError(error)
                    }
                    return
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8) else { return }

        recordParse()

        do {
            let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
            guard let channel = response.channel?.alternatives?.first else { return }

            for word in channel.words ?? [] {
                let event = RawTranscriptEvent(
                    text: word.punctuatedWord ?? word.word,
                    speakerIndex: word.speaker,
                    confidence: word.confidence,
                    isFinal: response.isFinal ?? false,
                    audioStartTime: word.start,
                    audioEndTime: word.end
                )
                await eventHub.publish(event)
            }

            if channel.words == nil || channel.words?.isEmpty == true,
               let transcript = channel.transcript, !transcript.isEmpty {
                let event = RawTranscriptEvent(
                    text: transcript,
                    speakerIndex: nil,
                    confidence: channel.confidence ?? 0,
                    isFinal: response.isFinal ?? false,
                    audioStartTime: response.start ?? 0,
                    audioEndTime: (response.start ?? 0) + (response.duration ?? 0)
                )
                await eventHub.publish(event)
            }
        } catch {
            logger.warning("Failed to decode Deepgram response: \(error.localizedDescription)")
            recordParseError()
        }
    }

    private func recordParse() {
        parseTimes.append(Date())
        pruneWindow()
    }

    private func recordParseError() {
        parseErrors.append(Date())
        pruneWindow()
        let errorRate = Double(parseErrors.count) / Double(max(parseTimes.count, 1))
        if errorRate > errorRateThreshold {
            _health = .degraded(reason: "parse error rate \(Int(errorRate * 100))%")
        }
    }

    private func pruneWindow() {
        let now = Date()
        parseErrors.removeAll { now.timeIntervalSince($0) > errorWindowSeconds }
        parseTimes.removeAll { now.timeIntervalSince($0) > errorWindowSeconds }
    }

    private func handleReceiveError(_ error: Error) {
        let nsError = error as NSError
        if nsError.code == 401 || nsError.code == 1008 {
            _health = .failed(error: ConfigError(message: "Deepgram auth rejected"))
            logger.error("Auth failure — not retrying")
            return
        }
        logger.error("WebSocket receive error: \(error.localizedDescription)")
        _health = .degraded(reason: "connection lost")
        Task { [weak self] in await self?.attemptReconnect() }
    }

    private func attemptReconnect() async {
        guard !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }

        guard reconnectAttempts < maxReconnectAttempts else {
            _health = .failed(error: ConfigError(message: "Max reconnect attempts exceeded"))
            return
        }
        let delay = reconnectDelays[min(reconnectAttempts, reconnectDelays.count - 1)]
        reconnectAttempts += 1
        logger.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempts))")
        try? await Task.sleep(for: .seconds(delay))

        let lastSeq = lastSentSequence
        webSocketTask?.cancel()
        webSocketTask = nil
        receiveTask?.cancel()

        guard let apiKey = try? await config.require(EnvKey.deepgramAPIKey) else {
            _health = .failed(error: ConfigError(message: "Missing API key on reconnect"))
            return
        }
        try? await connect(apiKey: apiKey)

        // Replay buffered frames that weren't sent before disconnect
        if let provider = replayProvider {
            let frames = await provider.replayFrames(after: lastSeq)
            for frame in frames {
                let event = AudioFrameEvent(
                    audioData: frame.data,
                    sequenceNumber: frame.seq
                )
                sendAudio(event)
            }
            logger.info("Replayed \(frames.count) buffered frames after reconnect")
        }
    }
}

// MARK: - Deepgram JSON Models

struct DeepgramResponse: Decodable, Sendable {
    let channel: DeepgramChannel?
    let isFinal: Bool?
    let start: Double?
    let duration: Double?

    enum CodingKeys: String, CodingKey {
        case channel
        case isFinal = "is_final"
        case start, duration
    }
}

struct DeepgramChannel: Decodable, Sendable {
    let alternatives: [DeepgramAlternative]?
}

struct DeepgramAlternative: Decodable, Sendable {
    let transcript: String?
    let confidence: Double?
    let words: [DeepgramWord]?
}

struct DeepgramWord: Decodable, Sendable {
    let word: String
    let start: Double
    let end: Double
    let confidence: Double
    let speaker: Int?
    let punctuatedWord: String?

    enum CodingKeys: String, CodingKey {
        case word, start, end, confidence, speaker
        case punctuatedWord = "punctuated_word"
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: DeepgramStreamingActor with replay on reconnect, error rate tracking"
```

---

### Task 9: TranscriptProjectionActor (with interim staging)

**Files:**
- Create: `Banti/Banti/Modules/Microphone/TranscriptProjectionActor.swift`
- Create: `Banti/BantiTests/TranscriptProjectionActorTests.swift`

- [ ] **Step 1: Write TranscriptProjectionActor tests**

```swift
import XCTest
@testable import Banti

final class TranscriptProjectionActorTests: XCTestCase {
    func testFinalResultPublishesSegment() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        let exp = XCTestExpectation(description: "segment received")
        var segment: TranscriptSegmentEvent?

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            segment = event
            exp.fulfill()
        }

        try? await projection.start()

        await hub.publish(RawTranscriptEvent(
            text: "hello", speakerIndex: 0, confidence: 0.95,
            isFinal: true, audioStartTime: 0.0, audioEndTime: 1.0
        ))
        await fulfillment(of: [exp], timeout: 2)

        XCTAssertEqual(segment?.text, "hello")
        XCTAssertEqual(segment?.speakerLabel, "Speaker 1")
        XCTAssertTrue(segment?.isFinal ?? false)
    }

    func testSpeakerMappingIsStable() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        var segments: [TranscriptSegmentEvent] = []
        let exp = XCTestExpectation(description: "two segments")
        exp.expectedFulfillmentCount = 2

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            if event.isFinal {
                segments.append(event)
                exp.fulfill()
            }
        }

        try? await projection.start()

        await hub.publish(RawTranscriptEvent(
            text: "first", speakerIndex: 0, confidence: 0.9,
            isFinal: true, audioStartTime: 0, audioEndTime: 1
        ))
        await hub.publish(RawTranscriptEvent(
            text: "second", speakerIndex: 1, confidence: 0.9,
            isFinal: true, audioStartTime: 1, audioEndTime: 2
        ))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(segments[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(segments[1].speakerLabel, "Speaker 2")
    }

    func testInterimResultsPublishNonFinal() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        let exp = XCTestExpectation(description: "interim segment")
        var segment: TranscriptSegmentEvent?

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            segment = event
            exp.fulfill()
        }

        try? await projection.start()

        await hub.publish(RawTranscriptEvent(
            text: "hel", speakerIndex: 0, confidence: 0.5,
            isFinal: false, audioStartTime: 0, audioEndTime: 0.5
        ))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertFalse(segment?.isFinal ?? true)
        XCTAssertEqual(segment?.text, "hel")
    }

    func testTimestampDedup() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        var segments: [TranscriptSegmentEvent] = []

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            if event.isFinal { segments.append(event) }
        }

        try? await projection.start()

        await hub.publish(RawTranscriptEvent(
            text: "hello", speakerIndex: 0, confidence: 0.9,
            isFinal: true, audioStartTime: 0, audioEndTime: 1
        ))
        // Duplicate with overlapping time range
        await hub.publish(RawTranscriptEvent(
            text: "hello", speakerIndex: 0, confidence: 0.9,
            isFinal: true, audioStartTime: 0.5, audioEndTime: 1
        ))

        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(segments.count, 1)
    }
}
```

- [ ] **Step 2: Run tests, verify fail**

- [ ] **Step 3: Implement TranscriptProjectionActor with interim staging**

```swift
import Foundation
import os

actor TranscriptProjectionActor: PerceptionModule {
    let id = ModuleID("transcript-projection")
    let capabilities: Set<Capability> = [.projection]

    private let logger = Logger(subsystem: "com.banti.transcript-projection", category: "Projection")
    private let eventHub: EventHubActor
    private var subscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy

    private var speakerMap: [Int: String] = [:]
    private var nextSpeakerNumber = 1
    private var finalizedEndTime: TimeInterval = 0

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    func start() async throws {
        subscriptionID = await eventHub.subscribe(RawTranscriptEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleRawTranscript(event)
        }
        _health = .healthy
    }

    func stop() async {
        if let subID = subscriptionID {
            await eventHub.unsubscribe(subID)
            subscriptionID = nil
        }
    }

    func health() -> ModuleHealth { _health }

    private func handleRawTranscript(_ event: RawTranscriptEvent) async {
        guard !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if event.isFinal {
            if event.audioEndTime <= finalizedEndTime { return }

            let label = speakerLabel(for: event.speakerIndex)
            let segment = TranscriptSegmentEvent(
                speakerLabel: label,
                text: event.text,
                startTime: event.audioStartTime,
                endTime: event.audioEndTime,
                isFinal: true
            )
            finalizedEndTime = max(finalizedEndTime, event.audioEndTime)
            await eventHub.publish(segment)
        } else {
            let label = speakerLabel(for: event.speakerIndex)
            let segment = TranscriptSegmentEvent(
                speakerLabel: label,
                text: event.text,
                startTime: event.audioStartTime,
                endTime: event.audioEndTime,
                isFinal: false
            )
            await eventHub.publish(segment)
        }
    }

    private func speakerLabel(for index: Int?) -> String {
        guard let index else { return "Speaker ?" }
        if let existing = speakerMap[index] { return existing }
        let label = "Speaker \(nextSpeakerNumber)"
        nextSpeakerNumber += 1
        speakerMap[index] = label
        return label
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: TranscriptProjectionActor with interim staging, speaker mapping, dedup"
```

---

### Task 10: TranscriptViewModel + TranscriptView (with interim support)

**Files:**
- Create: `Banti/Banti/UI/TranscriptViewModel.swift`
- Create: `Banti/Banti/UI/TranscriptView.swift`

- [ ] **Step 1: Implement TranscriptViewModel**

Handles both final segments (appended) and interim segments (replace last non-final).

```swift
import Foundation
import SwiftUI

@MainActor
final class TranscriptViewModel: ObservableObject {
    @Published var segments: [TranscriptSegmentEvent] = []
    @Published var isListening = false
    private let eventHub: EventHubActor
    private var subscriptionID: SubscriptionID?

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    func startListening() async {
        subscriptionID = await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] event in
            await MainActor.run {
                guard let self else { return }
                if event.isFinal {
                    // Remove any trailing interim segment, then append final
                    if let last = self.segments.last, !last.isFinal {
                        self.segments.removeLast()
                    }
                    self.segments.append(event)
                } else {
                    // Replace or append interim
                    if let last = self.segments.last, !last.isFinal {
                        self.segments[self.segments.count - 1] = event
                    } else {
                        self.segments.append(event)
                    }
                }
            }
        }
        isListening = true
    }

    func stopListening() async {
        if let subID = subscriptionID {
            await eventHub.unsubscribe(subID)
            subscriptionID = nil
        }
        isListening = false
    }
}
```

- [ ] **Step 2: Implement TranscriptView**

```swift
import SwiftUI

struct TranscriptView: View {
    @ObservedObject var viewModel: TranscriptViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            transcriptList
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var headerBar: some View {
        HStack {
            Circle()
                .fill(viewModel.isListening ? Color.red : Color.gray)
                .frame(width: 10, height: 10)
            Text(viewModel.isListening ? "Listening..." : "Stopped")
                .font(.headline)
            Spacer()
            Text("\(viewModel.segments.filter(\.isFinal).count) segments")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.segments) { segment in
                        segmentRow(segment)
                            .id(segment.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.segments.count) { _, _ in
                if let last = viewModel.segments.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func segmentRow(_ segment: TranscriptSegmentEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(segment.speakerLabel)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(colorForSpeaker(segment.speakerLabel))
                .frame(width: 80, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.text)
                    .font(.body)
                    .opacity(segment.isFinal ? 1.0 : 0.5)
                Text(formatTime(segment.startTime))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func colorForSpeaker(_ label: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]
        let hash = abs(label.hashValue)
        return colors[hash % colors.count]
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
```

- [ ] **Step 3: Build to verify compilation**

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: TranscriptView + ViewModel with interim display and auto-scroll"
```

---

### Task 11: BantiApp Wiring + Lifecycle

**Files:**
- Modify: `Banti/Banti/BantiApp.swift`

- [ ] **Step 1: Wire all actors with sleep/wake lifecycle handling**

```swift
import SwiftUI
import Combine

@main
struct BantiApp: App {
    @StateObject private var viewModel: TranscriptViewModel

    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let stateRegistry: StateRegistryActor
    private let supervisor: ModuleSupervisorActor
    private let micCapture: MicrophoneCaptureActor
    private let deepgram: DeepgramStreamingActor
    private let projection: TranscriptProjectionActor

    init() {
        let envPath = Bundle.main.path(forResource: ".env", ofType: nil)
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".env").path

        let hub = EventHubActor()
        let cfg = ConfigActor(envFilePath: envPath)
        let reg = StateRegistryActor()
        let sup = ModuleSupervisorActor(eventHub: hub, stateRegistry: reg)
        let mic = MicrophoneCaptureActor(eventHub: hub)
        let dg = DeepgramStreamingActor(eventHub: hub, config: cfg, replayProvider: mic)
        let proj = TranscriptProjectionActor(eventHub: hub)

        self.eventHub = hub
        self.config = cfg
        self.stateRegistry = reg
        self.supervisor = sup
        self.micCapture = mic
        self.deepgram = dg
        self.projection = proj

        let vm = TranscriptViewModel(eventHub: hub)
        _viewModel = StateObject(wrappedValue: vm)
    }

    var body: some Scene {
        WindowGroup {
            TranscriptView(viewModel: viewModel)
                .task { await registerAndStart() }
                .onReceive(
                    NSWorkspace.shared.notificationCenter
                        .publisher(for: NSWorkspace.didWakeNotification)
                ) { _ in
                    Task {
                        try? await supervisor.restart(micCapture.id)
                    }
                }
        }
    }

    private func registerAndStart() async {
        await supervisor.register(micCapture,
                                  restartPolicy: .onFailure(maxRetries: 3, backoff: 2))
        await supervisor.register(deepgram,
                                  restartPolicy: .onFailure(maxRetries: 5, backoff: 1))
        await supervisor.register(projection,
                                  restartPolicy: .onFailure(maxRetries: 3, backoff: 1))

        do {
            try await supervisor.startAll()
            await viewModel.startListening()
        } catch {
            print("Failed to start perception pipeline: \(error)")
        }
    }
}
```

- [ ] **Step 2: Build full project**

```bash
cd Banti && xcodegen generate
xcodebuild -project Banti.xcodeproj -scheme Banti -destination 'platform=macOS' build
```

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: wire all actors in BantiApp with sleep/wake lifecycle"
```

---

### Task 12: Final Test Run + Cleanup

- [ ] **Step 1: Run all tests**

```bash
cd Banti && xcodebuild test -project Banti.xcodeproj -scheme BantiTests -destination 'platform=macOS'
```

- [ ] **Step 2: Fix any failures**

- [ ] **Step 3: Final commit**

```bash
git add -A && git commit -m "chore: all tests passing, v1 mic ASR + diarization complete"
```
