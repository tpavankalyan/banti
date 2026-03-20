// Sources/BantiCore/BrainstemNode.swift
import Foundation

public actor BrainstemNode: CorticalNode {
    public let id = "brainstem"
    public let subscribedTopics = ["brain.route"]
    private let cerebras: CerebrasCompletion
    private var _bus: EventBus?

    private static let defaultSystemPrompt = """
    You are banti's brainstem — instant reflex. Speak in 1-2 short natural sentences.
    React to what's happening right now. Be warm, direct, human.
    If there is nothing worth saying, respond with exactly: [silent]
    Plain prose only. No JSON.
    """
    private var systemPrompt: String = BrainstemNode.defaultSystemPrompt

    public func setSystemPrompt(_ prompt: String) async {
        systemPrompt = prompt
    }

    public init(cerebras: @escaping CerebrasCompletion) { self.cerebras = cerebras }

    public func start(bus: EventBus) async {
        _bus = bus
        await bus.subscribe(topic: "brain.route") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        guard case .brainRoute(let route) = event.payload,
              route.tracks.contains("brainstem"),
              let bus = _bus else { return }
        do {
            let userContent = "Episode: \(route.episode.text)\nTone: \(route.episode.emotionalTone)"
            let text = try await cerebras("llama3.1-8b", systemPrompt, userContent, 80)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != "[silent]" && !trimmed.isEmpty else { return }
            let response = BrainResponsePayload(track: "brainstem", text: trimmed,
                                                activatedTracks: route.tracks,
                                                episodeID: route.episode.episodeID)
            await bus.publish(
                BantiEvent(source: id, topic: "brain.brainstem.response", surprise: 0,
                           payload: .brainResponse(response)),
                topic: "brain.brainstem.response"
            )
        } catch {
            print("[banti:brainstem] cerebras error: \(error)")
        }
    }
}
