// Sources/BantiCore/SurpriseDetector.swift
import Foundation

public actor SurpriseDetector: CorticalNode {
    public let id = "surprise_detector"
    public let subscribedTopics = ["sensor.*"]

    private let cerebras: CerebrasCompletion
    private var lastDescriptions: [String: String] = [:]  // topic → last text

    private static let defaultSystemPrompt = """
    You are a surprise filter. Given the previous and current description of a sensor event,
    output JSON: {"surprise": <float 0-1>} where 0 means nothing changed and 1 means very surprising.
    Respond with JSON only.
    """
    private var systemPrompt: String = SurpriseDetector.defaultSystemPrompt

    public func setSystemPrompt(_ prompt: String) async {
        systemPrompt = prompt
    }

    public init(cerebras: @escaping CerebrasCompletion) {
        self.cerebras = cerebras
    }

    public func start(bus: EventBus) async {
        await bus.subscribe(topic: "sensor.*") { [weak self] event in
            await self?.handle(event)
        }
        self._bus = bus
    }

    private var _bus: EventBus?
    private var lastCallTimes: [String: Date] = [:]
    private var inFlightTopics: Set<String> = []
    private static let minCallIntervalSeconds: TimeInterval = 2.0

    public func handle(_ event: BantiEvent) async {
        let now = Date()
        let throttleKey = throttleKey(for: event)
        guard !inFlightTopics.contains(throttleKey) else { return }
        let lastCallTime = lastCallTimes[throttleKey] ?? .distantPast
        guard now.timeIntervalSince(lastCallTime) >= SurpriseDetector.minCallIntervalSeconds else { return }
        guard let bus = _bus else { return }
        inFlightTopics.insert(throttleKey)
        defer { inFlightTopics.remove(throttleKey) }
        let description = describeEvent(event)
        let previous = lastDescriptions[throttleKey] ?? "(nothing)"

        let userContent = "Previous: \(previous)\nCurrent: \(description)"
        let score: Float
        do {
            let response = try await cerebras("llama3.1-8b", systemPrompt, userContent, 20)
            guard let json = LLMJSON.decode([String: Float].self, from: response),
                  let s = json["surprise"] else {
                print("[banti:surprise_detector] bad JSON from cerebras: \(response)")
                return
            }
            score = s
        } catch {
            print("[banti:surprise_detector] cerebras error: \(error)")
            return
        }

        lastDescriptions[throttleKey] = description
        lastCallTimes[throttleKey] = now
        guard score >= 0.3 else { return }
        let forwarded = BantiEvent(source: event.source, topic: event.topic,
                                   surprise: score, payload: event.payload)
        await bus.publish(forwarded, topic: "gate.surprise")
    }

    private func describeEvent(_ event: BantiEvent) -> String {
        switch event.payload {
        case .speechDetected(let p): return "Speech: \(p.transcript)"
        case .faceUpdate(let p): return "Face: \(p.personName ?? "unknown") confidence \(p.confidence)"
        case .screenUpdate(let p): return "Screen: \(p.interpretation)"
        case .emotionUpdate(let p): return "Emotion: \(p.emotions.first.map { "\($0.label) \($0.score)" } ?? "none")"
        case .soundUpdate(let p): return "Sound: \(p.label)"
        default: return "event:\(event.topic)"
        }
    }

    private func throttleKey(for event: BantiEvent) -> String {
        switch event.payload {
        case .speechDetected:
            return "\(event.topic):speech"
        case .emotionUpdate(let payload):
            return "\(event.topic):emotion:\(payload.source)"
        case .faceUpdate:
            return "\(event.topic):face"
        case .screenUpdate:
            return "\(event.topic):screen"
        case .soundUpdate:
            return "\(event.topic):sound"
        default:
            return event.topic
        }
    }
}
