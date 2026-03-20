// Sources/BantiCore/SurpriseDetector.swift
import Foundation

public actor SurpriseDetector: CorticalNode {
    public let id = "surprise_detector"
    public let subscribedTopics = ["sensor.*"]

    private let cerebras: CerebrasCompletion
    private var lastDescriptions: [String: String] = [:]  // topic → last text

    private static let systemPrompt = """
    You are a surprise filter. Given the previous and current description of a sensor event,
    output JSON: {"surprise": <float 0-1>} where 0 means nothing changed and 1 means very surprising.
    Respond with JSON only.
    """

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

    public func handle(_ event: BantiEvent) async {
        guard let bus = _bus else { return }
        let description = describeEvent(event)
        let previous = lastDescriptions[event.topic] ?? "(nothing)"
        lastDescriptions[event.topic] = description

        let userContent = "Previous: \(previous)\nCurrent: \(description)"
        let score: Float
        do {
            let response = try await cerebras("llama3.1-8b", Self.systemPrompt, userContent, 20)
            guard let data = response.data(using: .utf8),
                  let json = try? JSONDecoder().decode([String: Float].self, from: data),
                  let s = json["surprise"] else { return }
            score = s
        } catch {
            return // silently drop on Cerebras error
        }

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
}
