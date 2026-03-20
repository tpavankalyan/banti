// Sources/BantiCore/LimbicNode.swift
import Foundation

public actor LimbicNode: CorticalNode {
    public let id = "limbic"
    public let subscribedTopics = ["brain.route"]
    private let cerebras: CerebrasCompletion
    private var _bus: EventBus?

    private static let defaultSystemPrompt = """
    You are banti's limbic system. Read the emotional content and respond with empathy. 1-2 sentences.
    [silent] if no emotional content worth acknowledging.
    Plain prose only. No JSON.
    """
    private var systemPrompt: String = LimbicNode.defaultSystemPrompt

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
              route.tracks.contains("limbic"),
              let bus = _bus else { return }
        do {
            let userContent = "Episode: \(route.episode.text)\nTone: \(route.episode.emotionalTone)"
            let text = try await cerebras("llama3.1-8b", systemPrompt, userContent, 80)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != "[silent]" && !trimmed.isEmpty else { return }
            let response = BrainResponsePayload(track: "limbic", text: trimmed,
                                                activatedTracks: route.tracks,
                                                episodeID: route.episode.episodeID)
            await bus.publish(
                BantiEvent(source: id, topic: "brain.limbic.response", surprise: 0,
                           payload: .brainResponse(response)),
                topic: "brain.limbic.response"
            )
        } catch {
            print("[banti:limbic] cerebras error: \(error)")
        }
    }
}
