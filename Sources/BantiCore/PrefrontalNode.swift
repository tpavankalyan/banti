// Sources/BantiCore/PrefrontalNode.swift
import Foundation

public actor PrefrontalNode: CorticalNode {
    public let id = "prefrontal"
    public let subscribedTopics = ["brain.route", "memory.retrieve"]
    private let cerebras: CerebrasCompletion
    private var _bus: EventBus?

    // Cache: personID → (payload, receivedAt)
    private var memoryCache: [String: (MemoryRetrievedPayload, Date)] = [:]

    private static let defaultSystemPrompt = """
    You are banti's prefrontal cortex — deep reasoning and memory. Given the episode and any known facts about the participants, produce a thoughtful response. 2-4 sentences.
    If nothing meaningful can be added beyond what brainstem already covers, respond with exactly: [silent]
    Plain prose only. No JSON.
    """
    private var systemPrompt: String = PrefrontalNode.defaultSystemPrompt

    public func setSystemPrompt(_ prompt: String) async {
        systemPrompt = prompt
    }

    public init(cerebras: @escaping CerebrasCompletion) { self.cerebras = cerebras }

    public func start(bus: EventBus) async {
        _bus = bus
        for topic in subscribedTopics {
            await bus.subscribe(topic: topic) { [weak self] event in
                await self?.handle(event)
            }
        }
    }

    public func handle(_ event: BantiEvent) async {
        switch event.payload {
        case .brainRoute(let route):
            guard route.tracks.contains("prefrontal"), let bus = _bus else { return }
            await respond(to: route, bus: bus)
        case .memoryRetrieved(let memory):
            memoryCache[memory.personID] = (memory, Date())
        default:
            break
        }
    }

    private func respond(to route: BrainRoutePayload, bus: EventBus) async {
        // Collect cached memories for participants (within last 30s)
        let cutoff = Date().addingTimeInterval(-30)
        let relevantFacts = route.episode.participants.compactMap { name -> String? in
            guard let (mem, date) = memoryCache.values.first(where: { $0.0.personName == name }),
                  date > cutoff else { return nil }
            return "About \(name): \(mem.facts.joined(separator: "; "))"
        }.joined(separator: "\n")

        var userContent = "Episode: \(route.episode.text)\nTone: \(route.episode.emotionalTone)"
        if !relevantFacts.isEmpty {
            userContent += "\nKnown facts:\n\(relevantFacts)"
        }

        do {
            let text = try await cerebras("llama-3.3-70b", systemPrompt, userContent, 150)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != "[silent]" && !trimmed.isEmpty else { return }
            let response = BrainResponsePayload(track: "prefrontal", text: trimmed,
                                                activatedTracks: route.tracks)
            await bus.publish(
                BantiEvent(source: id, topic: "brain.prefrontal.response", surprise: 0,
                           payload: .brainResponse(response)),
                topic: "brain.prefrontal.response"
            )
        } catch { /* drop */ }
    }
}
