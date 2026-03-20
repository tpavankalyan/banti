// Sources/BantiCore/TemporalBinder.swift
import Foundation

public actor TemporalBinder: CorticalNode {
    public let id = "temporal_binder"
    public let subscribedTopics = ["gate.surprise"]

    private let cerebras: CerebrasCompletion
    private let windowNs: UInt64

    private var pendingEvents: [BantiEvent] = []
    private var windowTask: Task<Void, Never>?
    private var _bus: EventBus?

    private static let defaultSystemPrompt = """
    Fuse these sensor events into a single natural-language episode description.
    Output JSON only: {"text":"<episode>","participants":["<name>"],"emotionalTone":"<tone>"}
    """
    private var systemPrompt: String = TemporalBinder.defaultSystemPrompt

    public func setSystemPrompt(_ prompt: String) async {
        systemPrompt = prompt
    }

    public init(cerebras: @escaping CerebrasCompletion, windowMs: Int = 500) {
        self.cerebras = cerebras
        self.windowNs = UInt64(windowMs) * 1_000_000
    }

    public func start(bus: EventBus) async {
        _bus = bus
        await bus.subscribe(topic: "gate.surprise") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        pendingEvents.append(event)
        // Debounce: cancel existing timer, start a new one
        windowTask?.cancel()
        let capturedEvents = pendingEvents
        let ns = windowNs
        windowTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await self?.flush(capturedEvents)
        }
    }

    private func flush(_ events: [BantiEvent]) async {
        guard !events.isEmpty, let bus = _bus else { return }
        pendingEvents.removeAll()

        let descriptions = events.map { describeEvent($0) }.joined(separator: "\n")
        let userContent = "Events to fuse:\n\(descriptions)"

        do {
            let response = try await cerebras("llama3.1-8b", systemPrompt, userContent, 100)
            guard let data = response.data(using: .utf8),
                  let json = try? JSONDecoder().decode(EpisodeJSON.self, from: data) else { return }
            let episode = EpisodePayload(text: json.text, participants: json.participants,
                                         emotionalTone: json.emotionalTone)
            await bus.publish(
                BantiEvent(source: id, topic: "episode.bound", surprise: 1.0,
                           payload: .episodeBound(episode)),
                topic: "episode.bound"
            )
        } catch { /* silently drop */ }
    }

    private func describeEvent(_ event: BantiEvent) -> String {
        switch event.payload {
        case .speechDetected(let p): return "[\(event.timestampNs)] Speech: \(p.transcript)"
        case .faceUpdate(let p): return "[\(event.timestampNs)] Face: \(p.personName ?? "unknown")"
        case .screenUpdate(let p): return "[\(event.timestampNs)] Screen: \(p.interpretation)"
        case .emotionUpdate(let p): return "[\(event.timestampNs)] Emotion: \(p.source) \(p.emotions.first?.label ?? "")"
        default: return "[\(event.timestampNs)] \(event.topic)"
        }
    }

    private struct EpisodeJSON: Codable {
        let text: String
        let participants: [String]
        let emotionalTone: String
    }
}
