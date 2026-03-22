# Screen Change Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the time-based throttle in `ScreenDescriptionActor` with perceptual change-gating so VLM calls only fire when the screen content has actually changed.

**Architecture:** A new `ScreenChangeDetectionActor` sits between `ScreenCaptureActor` and `ScreenDescriptionActor`. It uses `VNFeaturePrintObservation` (Vision framework) to compute a perceptual distance between successive frames and only publishes `ScreenChangeEvent` when `distance >= threshold` (default 0.05). `ScreenDescriptionActor` is updated to subscribe to `ScreenChangeEvent` instead of `ScreenFrameEvent`, and its time-throttle logic is removed entirely.

**Tech Stack:** Swift, XCTest, Vision.framework (`VNFeaturePrintObservation`), `EventHubActor` pub/sub, `BantiModule` protocol

---

## File Map

| Action | File | Responsibility |
|---|---|---|
| Create | `Banti/Banti/Modules/Perception/Screen/ScreenFrameDifferencer.swift` | `ScreenFrameDifferencer` protocol + `VNScreenFrameDifferencer` production actor |
| Create | `Banti/Banti/Core/Events/ScreenChangeEvent.swift` | New event type |
| Create | `Banti/Banti/Modules/Perception/Screen/ScreenChangeDetectionActor.swift` | Perceptual gating — subscribes to `ScreenFrameEvent`, publishes `ScreenChangeEvent` |
| Create | `BantiTests/Helpers/MockScreenFrameDifferencer.swift` | Test helper — controllable `Float?` sequence |
| Create | `BantiTests/ScreenChangeDetectionActorTests.swift` | Tests for the new actor |
| Modify | `Banti/Banti/Config/Environment.swift` | Add `EnvKey.screenChangeThreshold` |
| Modify | `Banti/Banti/Core/BantiModule.swift` | Add `.screenChangeDetection` capability |
| Modify | `Banti/Banti/Core/Events/ScreenDescriptionEvent.swift` | Add `changeDistance: Float?`, replace `init` |
| Modify | `Banti/Banti/Modules/Perception/Screen/ScreenDescriptionActor.swift` | Subscribe to `ScreenChangeEvent`, remove time-throttle |
| Modify | `BantiTests/ScreenDescriptionActorTests.swift` | Update tests to use `ScreenChangeEvent` |
| Modify | `Banti/Banti/BantiApp.swift` | Wire `ScreenChangeDetectionActor` into pipeline |

---

## Task 1: Add EnvKey and Capability constants

These are the foundation that every other task depends on.

**Files:**
- Modify: `Banti/Banti/Config/Environment.swift`
- Modify: `Banti/Banti/Core/BantiModule.swift`

- [ ] **Step 1: Add `screenChangeThreshold` to `Environment.swift`**

Open `Banti/Banti/Config/Environment.swift`. After the `sceneChangeThreshold` line, add:

```swift
static let screenChangeThreshold     = "SCREEN_CHANGE_THRESHOLD"
```

The file should now end with:
```swift
    static let sceneChangeThreshold      = "SCENE_CHANGE_THRESHOLD"
    static let screenChangeThreshold     = "SCREEN_CHANGE_THRESHOLD"
}
```

- [ ] **Step 2: Add `screenChangeDetection` capability to `BantiModule.swift`**

Open `Banti/Banti/Core/BantiModule.swift`. After the `sceneChangeDetection` line, add:

```swift
    static let screenChangeDetection = Capability("screen-change-detection")
```

- [ ] **Step 3: Build to verify no errors**

In Xcode: Product → Build (⌘B). Expected: build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Banti/Banti/Config/Environment.swift Banti/Banti/Core/BantiModule.swift
git commit -m "feat: add screenChangeThreshold EnvKey and screenChangeDetection capability"
```

---

## Task 2: Create `ScreenChangeEvent`

**Files:**
- Create: `Banti/Banti/Core/Events/ScreenChangeEvent.swift`

- [ ] **Step 1: Create `ScreenChangeEvent.swift`**

Create `Banti/Banti/Core/Events/ScreenChangeEvent.swift`:

```swift
import Foundation

struct ScreenChangeEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let jpeg: Data
    /// nil = first frame (no prior reference). Raw perceptual distance for subsequent frames.
    /// Value is >= SCREEN_CHANGE_THRESHOLD as a consequence of gating, not a type guarantee.
    let changeDistance: Float?
    let sequenceNumber: UInt64
    let captureTime: Date

    init(jpeg: Data, changeDistance: Float?, sequenceNumber: UInt64, captureTime: Date) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("screen-change-detection")
        self.jpeg = jpeg
        self.changeDistance = changeDistance
        self.sequenceNumber = sequenceNumber
        self.captureTime = captureTime
    }
}
```

Add this file to the Xcode project under `Banti/Core/Events/` (same group as `SceneChangeEvent.swift`).

- [ ] **Step 2: Build to verify**

⌘B. Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Banti/Banti/Core/Events/ScreenChangeEvent.swift
git commit -m "feat: add ScreenChangeEvent"
```

---

## Task 3: Create `ScreenFrameDifferencer`

This is a direct port of `Camera/FrameDifferencer.swift` — same logic, screen-local ownership.

**Files:**
- Create: `Banti/Banti/Modules/Perception/Screen/ScreenFrameDifferencer.swift`

- [ ] **Step 1: Create `ScreenFrameDifferencer.swift`**

Create `Banti/Banti/Modules/Perception/Screen/ScreenFrameDifferencer.swift`:

```swift
// Banti/Banti/Modules/Perception/Screen/ScreenFrameDifferencer.swift
import Foundation
import Vision
import AppKit

// MARK: - Protocol

/// Computes perceptual distance between successive screen frames using VNFeaturePrint.
/// First call always returns nil (no prior reference). Subsequent calls return
/// [0, ∞) distance and update the stored reference.
protocol ScreenFrameDifferencer: Actor {
    func distance(from jpeg: Data) throws -> Float?
}

// MARK: - Production Implementation

actor VNScreenFrameDifferencer: ScreenFrameDifferencer {
    private var reference: VNFeaturePrintObservation?

    func distance(from jpeg: Data) throws -> Float? {
        let current = try computePrint(jpeg: jpeg)
        defer { reference = current }
        guard let ref = reference else { return nil }
        var dist: Float = 0
        try ref.computeDistance(&dist, to: current)
        return dist
    }

    private func computePrint(jpeg: Data) throws -> VNFeaturePrintObservation {
        guard let image = NSImage(data: jpeg),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw ScreenFrameDifferencerError("Cannot decode JPEG for feature print") }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first as? VNFeaturePrintObservation else {
            throw ScreenFrameDifferencerError("No feature print result returned")
        }
        return result
    }
}

// MARK: - Error

struct ScreenFrameDifferencerError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
```

Add to the Xcode project under `Banti/Modules/Perception/Screen/`.

- [ ] **Step 2: Build to verify**

⌘B. Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add "Banti/Banti/Modules/Perception/Screen/ScreenFrameDifferencer.swift"
git commit -m "feat: add ScreenFrameDifferencer protocol and VNScreenFrameDifferencer"
```

---

## Task 4: Create `MockScreenFrameDifferencer` test helper

**Files:**
- Create: `BantiTests/Helpers/MockScreenFrameDifferencer.swift`

- [ ] **Step 1: Write the failing test (capability check) to confirm the mock is needed**

Create `BantiTests/ScreenChangeDetectionActorTests.swift` with just the capability test:

```swift
import XCTest
@testable import Banti

final class ScreenChangeDetectionActorTests: XCTestCase {

    func testCapabilityIncludesScreenChangeDetection() {
        let actor = ScreenChangeDetectionActor(
            eventHub: EventHubActor(),
            config: ConfigActor(content: ""),
            differencer: MockScreenFrameDifferencer([nil])
        )
        XCTAssertTrue(actor.capabilities.contains(.screenChangeDetection))
    }
}
```

- [ ] **Step 2: Run the test — confirm it fails**

In Xcode: run `ScreenChangeDetectionActorTests`. Expected: **build failure** — `ScreenChangeDetectionActor` and `MockScreenFrameDifferencer` don't exist yet.

- [ ] **Step 3: Create `MockScreenFrameDifferencer.swift`**

Create `BantiTests/Helpers/MockScreenFrameDifferencer.swift`:

```swift
// BantiTests/Helpers/MockScreenFrameDifferencer.swift
import Foundation
@testable import Banti

/// Returns a pre-programmed sequence of distances. Repeats last value once exhausted.
/// Pass `nil` to simulate the first-frame case (no prior reference).
actor MockScreenFrameDifferencer: ScreenFrameDifferencer {
    private var distances: [Float?]
    private var index = 0

    init(_ distances: [Float?]) {
        self.distances = distances
    }

    func distance(from jpeg: Data) throws -> Float? {
        let d = distances[min(index, distances.count - 1)]
        index += 1
        return d
    }
}
```

Add to the Xcode project under `BantiTests/Helpers/` (same group as `MockFrameDifferencer.swift`).

- [ ] **Step 4: Build to verify the helper compiles**

⌘B. The test still fails to build (actor not yet created), but the helper file should compile without errors. Expected: error is only about `ScreenChangeDetectionActor` not existing.

- [ ] **Step 5: Commit**

```bash
git add BantiTests/Helpers/MockScreenFrameDifferencer.swift BantiTests/ScreenChangeDetectionActorTests.swift
git commit -m "test: add MockScreenFrameDifferencer helper and ScreenChangeDetectionActorTests stub"
```

---

## Task 5: Create `ScreenChangeDetectionActor`

**Files:**
- Create: `Banti/Banti/Modules/Perception/Screen/ScreenChangeDetectionActor.swift`

- [ ] **Step 1: Write ALL failing tests first**

Replace `BantiTests/ScreenChangeDetectionActorTests.swift` with the full test suite:

```swift
import XCTest
@testable import Banti

final class ScreenChangeDetectionActorTests: XCTestCase {

    private func makeFrame(seq: UInt64 = 1) -> ScreenFrameEvent {
        ScreenFrameEvent(jpeg: Data("fake".utf8), sequenceNumber: seq, displayWidth: 1920, displayHeight: 1080)
    }

    func testCapabilityIncludesScreenChangeDetection() {
        let actor = ScreenChangeDetectionActor(
            eventHub: EventHubActor(),
            config: ConfigActor(content: ""),
            differencer: MockScreenFrameDifferencer([nil])
        )
        XCTAssertTrue(actor.capabilities.contains(.screenChangeDetection))
    }

    func testFirstFrameAlwaysPublishes() async throws {
        // nil distance = no prior reference → always publish, changeDistance == nil
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCREEN_CHANGE_THRESHOLD=0.05")
        let exp = XCTestExpectation(description: "first frame published")
        let events = TestRecorder<ScreenChangeEvent>()

        _ = await hub.subscribe(ScreenChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockScreenFrameDifferencer([nil])
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertNil(snapshot.first?.changeDistance, "First frame must have nil changeDistance")
        XCTAssertEqual(snapshot.first?.sequenceNumber, 1)
    }

    func testFrameBelowThresholdIsDropped() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCREEN_CHANGE_THRESHOLD=0.05")
        let events = TestRecorder<ScreenChangeEvent>()

        _ = await hub.subscribe(ScreenChangeEvent.self) { event in
            await events.append(event)
        }

        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockScreenFrameDifferencer([0.02, 0.02])
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await hub.publish(makeFrame(seq: 2))
        try await Task.sleep(for: .milliseconds(200))

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 0, "Frames below threshold must be dropped")
    }

    func testFrameAtThresholdPublishes() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCREEN_CHANGE_THRESHOLD=0.05")
        let exp = XCTestExpectation(description: "frame at threshold published")
        let events = TestRecorder<ScreenChangeEvent>()

        _ = await hub.subscribe(ScreenChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        // distance = 0.05 == threshold → should publish
        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockScreenFrameDifferencer([0.05])
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.changeDistance ?? -1, 0.05, accuracy: 0.001)
    }

    func testFrameAboveThresholdPublishes() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCREEN_CHANGE_THRESHOLD=0.05")
        let exp = XCTestExpectation(description: "changed frame published")
        let events = TestRecorder<ScreenChangeEvent>()

        _ = await hub.subscribe(ScreenChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockScreenFrameDifferencer([0.20])
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.changeDistance ?? -1, 0.20, accuracy: 0.001)
    }

    func testDifferencerErrorDegradesHealth() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let callExp = XCTestExpectation(description: "differencer called")

        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: ThrowingScreenFrameDifferencer(onCall: { callExp.fulfill() })
        )
        try await actor.start()

        await hub.publish(makeFrame())
        await fulfillment(of: [callExp], timeout: 3)

        let deadline = Date().addingTimeInterval(2)
        var isDegraded = false
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            if case .degraded = await actor.health() { isDegraded = true; break }
        }
        XCTAssertTrue(isDegraded, "Expected degraded health after differencer error")
    }

    func testCaptureTimeMatchesFrameTimestamp() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCREEN_CHANGE_THRESHOLD=0.0")
        let exp = XCTestExpectation(description: "event received")
        let events = TestRecorder<ScreenChangeEvent>()

        _ = await hub.subscribe(ScreenChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockScreenFrameDifferencer([0.5])
        )
        try await actor.start()

        let sourceFrame = makeFrame()
        await hub.publish(sourceFrame)
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await events.snapshot()
        guard let first = snapshot.first else { XCTFail("No event"); return }
        XCTAssertEqual(first.captureTime.timeIntervalSince1970,
                       sourceFrame.timestamp.timeIntervalSince1970,
                       accuracy: 0.001,
                       "captureTime must be forwarded from ScreenFrameEvent.timestamp")
    }
}

// Throwing helper — defined locally
private actor ThrowingScreenFrameDifferencer: ScreenFrameDifferencer {
    let onCall: @Sendable () -> Void
    init(onCall: @escaping @Sendable () -> Void) { self.onCall = onCall }
    func distance(from jpeg: Data) throws -> Float? {
        onCall()
        throw ScreenFrameDifferencerError("test error")
    }
}
```

- [ ] **Step 2: Run tests — confirm they all fail**

Run `ScreenChangeDetectionActorTests`. Expected: build failure — `ScreenChangeDetectionActor` doesn't exist yet.

- [ ] **Step 3: Create `ScreenChangeDetectionActor.swift`**

Create `Banti/Banti/Modules/Perception/Screen/ScreenChangeDetectionActor.swift`:

```swift
// Banti/Banti/Modules/Perception/Screen/ScreenChangeDetectionActor.swift
import Foundation
import os

actor ScreenChangeDetectionActor: BantiModule {
    nonisolated let id = ModuleID("screen-change-detection")
    nonisolated let capabilities: Set<Capability> = [.screenChangeDetection]

    private let logger = Logger(subsystem: "com.banti.screen-change-detection", category: "Detection")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let differencer: any ScreenFrameDifferencer

    private var subscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy
    private var detectedCount = 0

    init(eventHub: EventHubActor, config: ConfigActor, differencer: (any ScreenFrameDifferencer)? = nil) {
        self.eventHub = eventHub
        self.config = config
        self.differencer = differencer ?? VNScreenFrameDifferencer()
    }

    func start() async throws {
        let threshold = Float(
            (await config.value(for: EnvKey.screenChangeThreshold)).flatMap(Float.init) ?? 0.05
        )

        // Deprecation warning for old time-throttle key
        if await config.value(for: EnvKey.screenDescriptionIntervalS) != nil {
            logger.warning("SCREEN_DESCRIPTION_INTERVAL_S is no longer used — screen descriptions are now change-driven. Remove this key to suppress this warning.")
        }

        subscriptionID = await eventHub.subscribe(ScreenFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleFrame(event, threshold: threshold)
        }
        _health = .healthy
        logger.notice("ScreenChangeDetectionActor started (threshold=\(threshold))")
    }

    func stop() async {
        if let id = subscriptionID {
            await eventHub.unsubscribe(id)
            subscriptionID = nil
        }
    }

    func health() async -> ModuleHealth { _health }

    private func handleFrame(_ event: ScreenFrameEvent, threshold: Float) async {
        do {
            let dist = try await differencer.distance(from: event.jpeg)

            // nil = first frame, no prior reference → always publish
            let shouldPublish = dist.map { $0 >= threshold } ?? true
            guard shouldPublish else { return }

            detectedCount += 1
            _health = .healthy

            let change = ScreenChangeEvent(
                jpeg: event.jpeg,
                changeDistance: dist,
                sequenceNumber: event.sequenceNumber,
                captureTime: event.timestamp
            )
            await eventHub.publish(change)

            if detectedCount == 1 || detectedCount.isMultiple(of: 20) {
                logger.notice("Screen change #\(self.detectedCount), dist=\(dist.map { String(format: "%.3f", $0) } ?? "nil")")
            }
        } catch {
            logger.error("ScreenFrameDifferencer error: \(error.localizedDescription, privacy: .public)")
            _health = .degraded(reason: "ScreenFrameDifferencer failed: \(error.localizedDescription)")
        }
    }
}
```

Add to the Xcode project under `Banti/Modules/Perception/Screen/`.

- [ ] **Step 4: Run tests — all should pass**

Run `ScreenChangeDetectionActorTests`. Expected: **all 6 tests green**.

- [ ] **Step 5: Commit**

```bash
git add Banti/Banti/Modules/Perception/Screen/ScreenChangeDetectionActor.swift BantiTests/ScreenChangeDetectionActorTests.swift
git commit -m "feat: add ScreenChangeDetectionActor with VNFeaturePrint perceptual gating"
```

---

## Task 6: Update `ScreenDescriptionEvent` — add `changeDistance`

**Files:**
- Modify: `Banti/Banti/Core/Events/ScreenDescriptionEvent.swift`

- [ ] **Step 1: Update `ScreenDescriptionEvent.swift`**

Replace the entire contents of `Banti/Banti/Core/Events/ScreenDescriptionEvent.swift`:

```swift
import Foundation

struct ScreenDescriptionEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String
    let captureTime: Date
    let responseTime: Date
    /// nil for first-frame descriptions (changeDistance was nil in the source ScreenChangeEvent).
    /// Raw measured perceptual distance otherwise.
    let changeDistance: Float?

    init(text: String, captureTime: Date, responseTime: Date, changeDistance: Float?) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("screen-description")
        self.text = text
        self.captureTime = captureTime
        self.responseTime = responseTime
        self.changeDistance = changeDistance
    }
}
```

- [ ] **Step 2: Build — expect build errors**

⌘B. Expected: build error at the `ScreenDescriptionActor.swift` call site — `ScreenDescriptionEvent` now requires `changeDistance:` argument. This is expected.

- [ ] **Step 3: Commit the event change (even though build is broken)**

```bash
git add Banti/Banti/Core/Events/ScreenDescriptionEvent.swift
git commit -m "feat: add changeDistance field to ScreenDescriptionEvent"
```

---

## Task 7: Update `ScreenDescriptionActor` — subscribe to `ScreenChangeEvent`, remove throttle

**Files:**
- Modify: `Banti/Banti/Modules/Perception/Screen/ScreenDescriptionActor.swift`

- [ ] **Step 1: Write the updated tests first**

Check if `BantiTests/ScreenDescriptionActorTests.swift` exists:

```bash
ls BantiTests/ScreenDescriptionActorTests.swift
```

If it exists, open it. If not, it needs to be created. Either way, replace or create the file with:

```swift
import XCTest
@testable import Banti

final class ScreenDescriptionActorTests: XCTestCase {

    private func makeChange(seq: UInt64 = 1, dist: Float? = 0.08) -> ScreenChangeEvent {
        ScreenChangeEvent(
            jpeg: Data("fake-jpeg".utf8),
            changeDistance: dist,
            sequenceNumber: seq,
            captureTime: Date()
        )
    }

    func testCapabilityIncludesScreenDescription() {
        let actor = ScreenDescriptionActor(
            eventHub: EventHubActor(),
            config: ConfigActor(content: ""),
            provider: MockVisionProvider(returning: "")
        )
        XCTAssertTrue(actor.capabilities.contains(.screenDescription))
    }

    func testPublishesScreenDescriptionEventOnChange() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let exp = XCTestExpectation(description: "screen description received")
        let descriptions = TestRecorder<ScreenDescriptionEvent>()

        _ = await hub.subscribe(ScreenDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = ScreenDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Xcode with Swift code visible.")
        )
        try await actor.start()

        await hub.publish(makeChange())
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.text, "Xcode with Swift code visible.")
    }

    func testChangeDistancePassedThrough() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let exp = XCTestExpectation(description: "description received")
        let descriptions = TestRecorder<ScreenDescriptionEvent>()

        _ = await hub.subscribe(ScreenDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = ScreenDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Screen.")
        )
        try await actor.start()

        await hub.publish(makeChange(dist: 0.12))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        guard let dist = snapshot.first?.changeDistance else { XCTFail("No event received"); return }
        XCTAssertEqual(dist, Float(0.12), accuracy: Float(0.001))
    }

    func testNilChangeDistancePassedThrough() async throws {
        // First-frame ScreenChangeEvent has nil changeDistance
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let exp = XCTestExpectation(description: "description received")
        let descriptions = TestRecorder<ScreenDescriptionEvent>()

        _ = await hub.subscribe(ScreenDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = ScreenDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Screen.")
        )
        try await actor.start()

        await hub.publish(makeChange(dist: nil))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        XCTAssertNil(snapshot.first?.changeDistance, "nil changeDistance must be propagated")
    }

    func testNoTimeThrottling() async throws {
        // Back-to-back ScreenChangeEvents must both trigger VLM calls — no residual throttle
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        var callCount = 0
        let secondExp = XCTestExpectation(description: "second description received")
        let descriptions = TestRecorder<ScreenDescriptionEvent>()

        _ = await hub.subscribe(ScreenDescriptionEvent.self) { event in
            await descriptions.append(event)
            callCount += 1
            if callCount >= 2 { secondExp.fulfill() }
        }

        let actor = ScreenDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Screen.")
        )
        try await actor.start()

        await hub.publish(makeChange(seq: 1))
        await hub.publish(makeChange(seq: 2))
        await fulfillment(of: [secondExp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        XCTAssertEqual(snapshot.count, 2, "Both back-to-back events must produce descriptions (no time throttle)")
    }

    func testVLMFailureDegradesHealth() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let callExp = XCTestExpectation(description: "VLM called")
        let provider = MockVisionProvider(throwing: VisionError("API unavailable")) {
            callExp.fulfill()
        }

        let actor = ScreenDescriptionActor(eventHub: hub, config: config, provider: provider)
        try await actor.start()

        await hub.publish(makeChange())
        await fulfillment(of: [callExp], timeout: 3)

        let deadline = Date().addingTimeInterval(2)
        var healthIsDegraded = false
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            if case .degraded = await actor.health() { healthIsDegraded = true; break }
        }
        XCTAssertTrue(healthIsDegraded, "Expected degraded health after VLM failure")
    }

    func testCaptureTimeMatchesChangeEventCaptureTime() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let exp = XCTestExpectation(description: "description received")
        let descriptions = TestRecorder<ScreenDescriptionEvent>()

        _ = await hub.subscribe(ScreenDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = ScreenDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Test screen.")
        )
        try await actor.start()

        let changeEvent = makeChange()
        await hub.publish(changeEvent)
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        guard let first = snapshot.first else { XCTFail("No event"); return }
        XCTAssertEqual(first.captureTime.timeIntervalSince1970,
                       changeEvent.captureTime.timeIntervalSince1970,
                       accuracy: 0.01,
                       "captureTime must come from ScreenChangeEvent.captureTime")
        XCTAssertGreaterThanOrEqual(first.responseTime, first.captureTime)
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

Run `ScreenDescriptionActorTests`. Expected: failures — actor still subscribes to `ScreenFrameEvent`.

- [ ] **Step 3: Rewrite `ScreenDescriptionActor.swift`**

Replace the full contents of `Banti/Banti/Modules/Perception/Screen/ScreenDescriptionActor.swift`:

```swift
import Foundation
import os

actor ScreenDescriptionActor: BantiModule {
    nonisolated let id = ModuleID("screen-description")
    nonisolated let capabilities: Set<Capability> = [.screenDescription]

    private let logger = Logger(subsystem: "com.banti.screen-description", category: "Screen")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let overrideProvider: (any VisionProvider)?

    private var subscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy
    private var describedCount = 0

    init(eventHub: EventHubActor, config: ConfigActor, provider: (any VisionProvider)? = nil) {
        self.eventHub = eventHub
        self.config = config
        self.overrideProvider = provider
    }

    func start() async throws {
        let provider = try await buildProvider()

        let prompt = (await config.value(for: EnvKey.screenDescriptionPrompt))
            ?? "Describe what is shown on this computer screen. Focus on the application in use, visible text, open documents, and what the user appears to be doing."

        subscriptionID = await eventHub.subscribe(ScreenChangeEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleChange(event, provider: provider, prompt: prompt)
        }

        _health = .healthy
        logger.notice("ScreenDescriptionActor started (change-driven)")
    }

    func stop() async {
        if let id = subscriptionID {
            await eventHub.unsubscribe(id)
            subscriptionID = nil
        }
    }

    func health() async -> ModuleHealth { _health }

    private func handleChange(
        _ event: ScreenChangeEvent,
        provider: any VisionProvider,
        prompt: String
    ) async {
        let captureTime = event.captureTime

        do {
            let description = try await provider.describe(jpeg: event.jpeg, prompt: prompt)
            let responseTime = Date()

            describedCount += 1
            _health = .healthy

            let screenEvent = ScreenDescriptionEvent(
                text: description,
                captureTime: captureTime,
                responseTime: responseTime,
                changeDistance: event.changeDistance
            )
            await eventHub.publish(screenEvent)

            if describedCount == 1 || describedCount.isMultiple(of: 10) {
                logger.notice("Published screen desc #\(self.describedCount): \(description.prefix(60), privacy: .public)")
            }
        } catch {
            logger.error("VisionProvider error: \(error.localizedDescription, privacy: .public)")
            _health = .degraded(reason: "VLM call failed: \(error.localizedDescription)")
        }
    }

    private func buildProvider() async throws -> any VisionProvider {
        if let override = overrideProvider { return override }

        let selected = ((await config.value(for: EnvKey.visionProvider)) ?? "claude")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch selected {
        case "claude":
            let key = try await config.require(EnvKey.anthropicAPIKey)
            let model = (await config.value(for: EnvKey.anthropicVisionModel)) ?? ClaudeVisionProvider.defaultModel
            logger.notice("Screen vision using Claude (\(model, privacy: .public))")
            return ClaudeVisionProvider(apiKey: key, model: model)

        default:
            throw VisionError("Unknown VISION_PROVIDER: \(selected). Supported: claude")
        }
    }
}
```

- [ ] **Step 4: Run tests — all should pass**

Run `ScreenDescriptionActorTests`. Expected: **all 7 tests green**. ⌘B must also succeed.

- [ ] **Step 5: Commit**

```bash
git add Banti/Banti/Modules/Perception/Screen/ScreenDescriptionActor.swift BantiTests/ScreenDescriptionActorTests.swift
git commit -m "feat: rewire ScreenDescriptionActor to subscribe ScreenChangeEvent, drop time throttle"
```

---

## Task 8: Wire `ScreenChangeDetectionActor` into `BantiApp`

**Files:**
- Modify: `Banti/Banti/BantiApp.swift`

- [ ] **Step 1: Add `screenChangeDetector` property and instantiation**

In `BantiApp.swift`:

1. Add a new stored property after `screenCapture`:
   ```swift
   private let screenChangeDetector: ScreenChangeDetectionActor
   ```

2. In `init()`, after `let screenCaptureActor = ScreenCaptureActor(...)`, add:
   ```swift
   let screenChangeDetectorActor = ScreenChangeDetectionActor(eventHub: hub, config: cfg)
   ```

3. Assign the stored property after `self.screenCapture = screenCaptureActor`:
   ```swift
   self.screenChangeDetector = screenChangeDetectorActor
   ```

4. Update the `bootstrap` call in `init()` to pass the new actor:
   ```swift
   await Self.bootstrap(
       sup: sup, eventLogger: loggerActor, mic: mic, dg: dg, proj: proj,
       camera: cameraActor, sceneChangeDetector: sceneChangeDetectorActor, sceneDesc: sceneDescActor,
       screenCapture: screenCaptureActor, screenChangeDetector: screenChangeDetectorActor,
       screenDesc: screenDescActor, activeApp: activeAppActor, axFocus: axFocusActor,
       contextSnapshot: contextSnapshotActor, turnDetector: turnDetectorActor,
       agentBridge: agentBridgeActor, memoryWriteBack: memoryWriteBackActor,
       tts: ttsActor, vm: vm
   )
   ```

- [ ] **Step 2: Update `bootstrap` signature and body**

Update the `bootstrap` static function signature to include `screenChangeDetector: ScreenChangeDetectionActor` after `screenCapture`.

In the bootstrap body, replace the two screen-related registration lines:

```swift
// OLD:
await sup.register(screenDesc, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
await sup.register(screenCapture, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [screenDesc.id])
```

With:

```swift
// NEW — registration order is load-bearing (see spec §7):
await sup.register(screenDesc,            restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
await sup.register(screenChangeDetector,  restartPolicy: .onFailure(maxRetries: 3, backoff: 1),
                   dependencies: [screenDesc.id])
await sup.register(screenCapture,         restartPolicy: .onFailure(maxRetries: 3, backoff: 2),
                   dependencies: [screenChangeDetector.id])
```

- [ ] **Step 3: Build to verify**

⌘B. Expected: build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Banti/Banti/BantiApp.swift
git commit -m "feat: wire ScreenChangeDetectionActor into app pipeline"
```

---

## Task 9: Run full test suite

- [ ] **Step 1: Run all tests**

In Xcode: Product → Test (⌘U).

Expected: all tests pass, no regressions.

- [ ] **Step 2: If any tests fail — investigate before proceeding**

Do not move on until all tests are green.

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat: screen change detection — perceptual gating replaces time throttle"
```

---

## Verification Checklist

After all tasks:

- [ ] `ScreenChangeDetectionActorTests` — 6 tests passing
- [ ] `ScreenDescriptionActorTests` — 7 tests passing (updated for change-event subscription)
- [ ] Full test suite clean (`⌘U`)
- [ ] `ScreenDescriptionEvent.changeDistance` is `Float?` (nil for first frame)
- [ ] `ScreenDescriptionActor` has no `lastDescribedAt` or `intervalS` — removed
- [ ] `BantiApp.swift` registers actors in order: `screenDesc` → `screenChangeDetector` → `screenCapture`
- [ ] `SCREEN_DESCRIPTION_INTERVAL_S` in `.env` causes startup warning, not error
