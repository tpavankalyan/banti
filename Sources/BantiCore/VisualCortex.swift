// Sources/BantiCore/VisualCortex.swift
import Foundation
import Vision

// MARK: - BusRef
// Thread-safe reference wrapper so a non-actor dispatcher can share the EventBus
// with the actor that sets it later (in `start(bus:)`).

final class VisualBusRef: @unchecked Sendable {
    private let lock = NSLock()
    private var _bus: EventBus?

    var bus: EventBus? {
        get { lock.lock(); defer { lock.unlock() }; return _bus }
        set { lock.lock(); defer { lock.unlock() }; _bus = newValue }
    }
}

// MARK: - VisualCortexDispatcher
// Implements PerceptionDispatcher so it can be injected into LocalPerception.
// Receives camera-frame Vision results and publishes them to EventBus.

final class VisualCortexDispatcher: PerceptionDispatcher, @unchecked Sendable {
    private let hume: HumeEmotionAnalyzer?
    private let activity: GPT4oActivityAnalyzer?
    private let gesture: GPT4oGestureAnalyzer?
    private let logger: Logger
    private let busRef: VisualBusRef

    // Throttle state protected by a lock (called from background DispatchQueue)
    private let throttleLock = NSLock()
    private var lastFired: [String: Date] = [:]

    init(
        hume: HumeEmotionAnalyzer?,
        activity: GPT4oActivityAnalyzer?,
        gesture: GPT4oGestureAnalyzer?,
        logger: Logger,
        busRef: VisualBusRef
    ) {
        self.hume = hume
        self.activity = activity
        self.gesture = gesture
        self.logger = logger
        self.busRef = busRef
    }

    func dispatch(jpegData: Data, source: String, events: [PerceptionEvent]) async {
        guard source == "camera" else { return }
        guard let bus = busRef.bus else { return }

        // Publish face detection immediately
        for event in events {
            if case .faceDetected(let obs) = event {
                let state = FaceState(
                    boundingBox: obs.boundingBox,
                    landmarksDetected: obs.landmarks != nil,
                    updatedAt: Date()
                )
                let payload = FacePayload(
                    boundingBox: state.boundingBox,
                    personID: nil,
                    personName: nil,
                    confidence: 1.0
                )
                let bantiEvent = BantiEvent(
                    source: "visual_cortex",
                    topic: "sensor.visual",
                    surprise: 0.5,
                    payload: .faceUpdate(payload)
                )
                await bus.publish(bantiEvent, topic: "sensor.visual")
            }
        }

        let hasFace  = events.contains { if case .faceDetected    = $0 { return true }; return false }
        let hasHuman = events.contains { if case .humanPresent    = $0 { return true }; return false }
        let hasBody  = events.contains { if case .bodyPoseDetected = $0 { return true }; return false }
        let hasHand  = events.contains { if case .handPoseDetected = $0 { return true }; return false }

        // Hume emotion analysis (throttled 2 s)
        if hasFace, let analyzer = hume, shouldFire(name: "hume", throttle: 2) {
            markFired(name: "hume")
            let capturedRef = busRef
            Task {
                guard let obs = await analyzer.analyze(jpegData: jpegData, events: events) else { return }
                guard case .emotion(let state) = obs else { return }
                guard let b = capturedRef.bus else { return }
                let emotions = state.emotions.map {
                    EmotionPayload.Emotion(label: $0.label, score: $0.score)
                }
                let payload = EmotionPayload(emotions: emotions, source: "hume_face")
                let emotionEvent = BantiEvent(
                    source: "visual_cortex",
                    topic: "sensor.visual",
                    surprise: 0.6,
                    payload: .emotionUpdate(payload)
                )
                await b.publish(emotionEvent, topic: "sensor.visual")
            }
        }

        // Activity analysis (throttled 5 s) — result goes to context in Phase 1; no bus event yet
        if (hasFace || hasHuman), let analyzer = activity, shouldFire(name: "activity", throttle: 5) {
            markFired(name: "activity")
            Task { _ = await analyzer.analyze(jpegData: jpegData, events: events) }
        }

        // Gesture analysis (throttled 3 s) — same
        if (hasBody || hasHand), let analyzer = gesture, shouldFire(name: "gesture", throttle: 3) {
            markFired(name: "gesture")
            Task { _ = await analyzer.analyze(jpegData: jpegData, events: events) }
        }
    }

    // MARK: - Throttle helpers

    private func shouldFire(name: String, throttle: Double) -> Bool {
        throttleLock.lock(); defer { throttleLock.unlock() }
        guard let last = lastFired[name] else { return true }
        return Date().timeIntervalSince(last) >= throttle
    }

    private func markFired(name: String) {
        throttleLock.lock(); defer { throttleLock.unlock() }
        lastFired[name] = Date()
    }
}

// MARK: - VisualCortex

/// Autonomous sensor node that owns the camera capture pipeline.
/// Publishes `sensor.visual` events (`FacePayload`, `EmotionPayload`) to the EventBus.
/// No incoming subscriptions — this is a pure sensor source.
public actor VisualCortex: CorticalNode {
    public let id = "visual_cortex"
    public let subscribedTopics: [String] = []

    private let localPerception: LocalPerception
    private let cameraCapture: CameraCapture
    private let busRef: VisualBusRef

    // MARK: - Inits

    /// Designated initialiser: pass pre-built objects (composable, testable).
    public init(localPerception: LocalPerception, cameraCapture: CameraCapture) {
        self.localPerception = localPerception
        self.cameraCapture = cameraCapture
        self.busRef = VisualBusRef()
        // Note: when using this init the busRef is not shared with any dispatcher;
        // callers must ensure LocalPerception's dispatcher references the same busRef.
        // Use `makeDefault(logger:)` for the fully-wired production path.
    }

    /// Internal init used by `makeDefault` so the shared `VisualBusRef` is consistent.
    internal init(
        _perception: LocalPerception,
        _camera: CameraCapture,
        _busRef: VisualBusRef
    ) {
        self.localPerception = _perception
        self.cameraCapture = _camera
        self.busRef = _busRef
    }

    /// Convenience factory — builds the full pipeline from environment keys.
    public static func makeDefault(logger: Logger) -> VisualCortex {
        let sharedBusRef = VisualBusRef()

        let env = ProcessInfo.processInfo.environment
        let hume = env["HUME_API_KEY"].map { HumeEmotionAnalyzer(apiKey: $0, logger: logger) }
        let (activity, gesture): (GPT4oActivityAnalyzer?, GPT4oGestureAnalyzer?) = {
            guard let key = env["OPENAI_API_KEY"] else { return (nil, nil) }
            return (GPT4oActivityAnalyzer(apiKey: key, logger: logger),
                    GPT4oGestureAnalyzer(apiKey: key, logger: logger))
        }()

        let dispatcher = VisualCortexDispatcher(
            hume: hume,
            activity: activity,
            gesture: gesture,
            logger: logger,
            busRef: sharedBusRef
        )
        let perception = LocalPerception(dispatcher: dispatcher)
        let deduplicator = Deduplicator()
        let camera = CameraCapture(
            logger: logger,
            deduplicator: deduplicator,
            frameProcessor: perception
        )

        return VisualCortex(_perception: perception, _camera: camera, _busRef: sharedBusRef)
    }

    // MARK: - CorticalNode

    public func start(bus: EventBus) async {
        busRef.bus = bus
        cameraCapture.start()
    }

    /// No-op — VisualCortex does not subscribe to any topics.
    public func handle(_ event: BantiEvent) async {}
}
