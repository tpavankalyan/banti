// Sources/BantiCore/MemoryConsolidator.swift
import Foundation

/// Typealias for the sidecar store function — injectable for tests.
public typealias SidecarStore = @Sendable (_ episodeText: String) async -> Void

public actor MemoryConsolidator: CorticalNode {
    public let id = "memory_consolidator"
    public let subscribedTopics = ["episode.bound"]

    private let cerebras: CerebrasCompletion
    private let storeSidecar: SidecarStore
    private var _bus: EventBus?

    private static let systemPrompt = """
    Given this episode, decide whether it is worth storing in long-term memory.
    Output JSON only: {"store":true,"reason":"<brief>"} or {"store":false,"reason":"<brief>"}
    Store if: involves a named person, has emotional significance, or contains factual information worth remembering.
    Skip if: generic background noise, empty environment, trivial chatter.
    """

    public init(cerebras: @escaping CerebrasCompletion, storeSidecar: @escaping SidecarStore) {
        self.cerebras = cerebras
        self.storeSidecar = storeSidecar
    }

    public func start(bus: EventBus) async {
        _bus = bus
        await bus.subscribe(topic: "episode.bound") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        guard case .episodeBound(let episode) = event.payload else { return }

        let userContent = "Episode: \(episode.text)\nParticipants: \(episode.participants.joined(separator: ", "))\nTone: \(episode.emotionalTone)"

        do {
            let response = try await cerebras("llama3.1-8b", Self.systemPrompt, userContent, 60)
            guard let data = response.data(using: .utf8),
                  let json = try? JSONDecoder().decode(StoreDecision.self, from: data),
                  json.store else { return }
            await storeSidecar(episode.text)
            if let bus = _bus {
                await bus.publish(
                    BantiEvent(source: id, topic: "memory.write", surprise: 0,
                               payload: .memorySaved(MemorySavedPayload(episodeID: episode.episodeID, stored: true))),
                    topic: "memory.write"
                )
            }
        } catch { /* drop */ }
    }

    private struct StoreDecision: Codable {
        let store: Bool
        let reason: String
    }
}
