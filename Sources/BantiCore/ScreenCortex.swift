// Sources/BantiCore/ScreenCortex.swift
import Foundation

// MARK: - ScreenBusRef
// Thread-safe reference wrapper so the non-actor dispatcher can share the
// EventBus (and optional BantiVoice) with the actor that sets them in `start(bus:)`.

final class ScreenBusRef: @unchecked Sendable {
    private let lock = NSLock()
    private var _bus: EventBus?
    private var _bantiVoice: BantiVoice?

    var bus: EventBus? {
        get { lock.lock(); defer { lock.unlock() }; return _bus }
        set { lock.lock(); defer { lock.unlock() }; _bus = newValue }
    }

    var bantiVoice: BantiVoice? {
        get { lock.lock(); defer { lock.unlock() }; return _bantiVoice }
        set { lock.lock(); defer { lock.unlock() }; _bantiVoice = newValue }
    }
}

// MARK: - ScreenCortexDispatcher
// Implements PerceptionDispatcher so it can be injected into LocalPerception.
// Receives screen-frame Vision results, calls GPT-4o, and publishes to EventBus.

final class ScreenCortexDispatcher: PerceptionDispatcher, @unchecked Sendable {
    private let screen: GPT4oScreenAnalyzer?
    private let logger: Logger
    private let busRef: ScreenBusRef

    // Throttle state protected by a lock (called from background DispatchQueue)
    private let throttleLock = NSLock()
    private var lastFiredScreen: Date?

    init(
        screen: GPT4oScreenAnalyzer?,
        logger: Logger,
        busRef: ScreenBusRef
    ) {
        self.screen = screen
        self.logger = logger
        self.busRef = busRef
    }

    func dispatch(jpegData: Data, source: String, events: [PerceptionEvent]) async {
        guard source == "screen" else { return }

        let hasText = events.contains { if case .textRecognized = $0 { return true }; return false }
        guard hasText, let analyzer = screen, shouldFireScreen(throttle: 4) else { return }

        markFiredScreen()

        guard let obs = await analyzer.analyze(jpegData: nil, events: events) else { return }
        guard case .screen(let state) = obs else { return }

        guard let bus = busRef.bus else { return }

        if let voice = busRef.bantiVoice {
            // Filter out banti's own speech from OCR lines and interpretation
            let rawText = state.ocrLines.joined(separator: "\n")
            let cleaned = await voice.suppressSelfEcho(in: rawText)
            let cleanedLines = cleaned
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
            let cleanedInterp = await voice.suppressSelfEcho(in: state.interpretation)

            let payload = ScreenPayload(ocrLines: cleanedLines, interpretation: cleanedInterp)
            let event = BantiEvent(
                source: "screen_cortex",
                topic: "sensor.screen",
                surprise: 0.6,
                payload: .screenUpdate(payload)
            )
            await bus.publish(event, topic: "sensor.screen")
        } else {
            let payload = ScreenPayload(ocrLines: state.ocrLines, interpretation: state.interpretation)
            let event = BantiEvent(
                source: "screen_cortex",
                topic: "sensor.screen",
                surprise: 0.6,
                payload: .screenUpdate(payload)
            )
            await bus.publish(event, topic: "sensor.screen")
        }
    }

    // MARK: - Throttle helpers

    private func shouldFireScreen(throttle: Double) -> Bool {
        throttleLock.lock(); defer { throttleLock.unlock() }
        guard let last = lastFiredScreen else { return true }
        return Date().timeIntervalSince(last) >= throttle
    }

    private func markFiredScreen() {
        throttleLock.lock(); defer { throttleLock.unlock() }
        lastFiredScreen = Date()
    }
}

// MARK: - ScreenCortex

/// Autonomous sensor node that owns the screen capture pipeline.
/// Publishes `sensor.screen` events (`ScreenPayload`) to the EventBus.
/// Optionally filters banti's own speech from OCR output (self-echo suppression).
/// No incoming subscriptions — this is a pure sensor source.
public actor ScreenCortex: CorticalNode {
    public let id = "screen_cortex"
    public let subscribedTopics: [String] = []

    private let localPerception: LocalPerception
    private let screenCapture: ScreenCapture
    private let busRef: ScreenBusRef

    // MARK: - Inits

    /// Designated initialiser: pass pre-built objects (composable, testable).
    public init(localPerception: LocalPerception, screenCapture: ScreenCapture) {
        self.localPerception = localPerception
        self.screenCapture = screenCapture
        self.busRef = ScreenBusRef()
    }

    /// Internal init used by `makeDefault` so the shared `ScreenBusRef` is consistent.
    internal init(
        _perception: LocalPerception,
        _capture: ScreenCapture,
        _busRef: ScreenBusRef
    ) {
        self.localPerception = _perception
        self.screenCapture = _capture
        self.busRef = _busRef
    }

    /// Convenience factory — builds the full pipeline from environment keys.
    public static func makeDefault(logger: Logger) -> ScreenCortex {
        let sharedBusRef = ScreenBusRef()

        let screenAnalyzer = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            .map { GPT4oScreenAnalyzer(apiKey: $0, logger: logger) }

        let dispatcher = ScreenCortexDispatcher(
            screen: screenAnalyzer,
            logger: logger,
            busRef: sharedBusRef
        )
        let perception = LocalPerception(dispatcher: dispatcher)
        let deduplicator = Deduplicator()
        let capture = ScreenCapture(
            logger: logger,
            deduplicator: deduplicator,
            frameProcessor: perception
        )

        return ScreenCortex(_perception: perception, _capture: capture, _busRef: sharedBusRef)
    }

    // MARK: - CorticalNode

    public func start(bus: EventBus) async {
        busRef.bus = bus
        await screenCapture.start()
    }

    /// No-op — ScreenCortex does not subscribe to any topics.
    public func handle(_ event: BantiEvent) async {}

    // MARK: - Self-echo filter

    /// Wire in a BantiVoice instance so OCR output is filtered for banti's own speech.
    /// Call before (or shortly after) `start(bus:)`.
    public func setBantiVoice(_ voice: BantiVoice) {
        busRef.bantiVoice = voice
    }
}
