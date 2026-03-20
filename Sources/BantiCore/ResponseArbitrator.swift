// Sources/BantiCore/ResponseArbitrator.swift
import Foundation

public actor ResponseArbitrator: CorticalNode {
    public let id = "response_arbitrator"
    public let subscribedTopics = ["brain.route", "brain.brainstem.response",
                                    "brain.limbic.response", "brain.prefrontal.response"]

    private let cerebras: CerebrasCompletion
    private let collectionWindowNs: UInt64
    private var _bus: EventBus?

    // Per-route collection state
    private var activatedTracks: [String] = []
    private var collectedResponses: [BrainResponsePayload] = []
    private var windowTask: Task<Void, Never>?

    private static let systemPrompt = """
    You are banti's response arbitrator. Given candidate responses from different brain tracks,
    produce an ordered list of sentences to speak. Suppress redundant content. Merge where natural.
    Prefer empathy before information. Output JSON only: {"sentences":["<s1>","<s2>",...]}
    If nothing is worth saying, return: {"sentences":[]}
    """

    public init(cerebras: @escaping CerebrasCompletion, collectionWindowMs: Int = 5000) {
        self.cerebras = cerebras
        self.collectionWindowNs = UInt64(collectionWindowMs) * 1_000_000
    }

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
            // New route: reset collection state and start window timer
            activatedTracks = route.tracks
            collectedResponses = []
            windowTask?.cancel()
            let ns = collectionWindowNs
            windowTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: ns)
                guard !Task.isCancelled else { return }
                await self?.flush()
            }
        case .brainResponse(let response):
            collectedResponses.append(response)
            // If all activated tracks have responded, flush early
            let respondedTracks = Set(collectedResponses.map { $0.track })
            let expectedTracks = Set(activatedTracks)
            if respondedTracks.isSuperset(of: expectedTracks) {
                windowTask?.cancel()
                await flush()
            }
        default:
            break
        }
    }

    private func flush() async {
        guard let bus = _bus else { return }
        defer { collectedResponses = []; activatedTracks = [] }

        if collectedResponses.isEmpty {
            // Timeout fallback: publish empty plan
            await bus.publish(
                BantiEvent(source: id, topic: "motor.speech_plan", surprise: 0,
                           payload: .speechPlan(SpeechPlanPayload(sentences: []))),
                topic: "motor.speech_plan"
            )
            return
        }

        let candidateText = collectedResponses
            .map { "[\($0.track)]: \($0.text)" }
            .joined(separator: "\n")

        do {
            let response = try await cerebras("llama3.1-8b", Self.systemPrompt, candidateText, 150)
            guard let data = response.data(using: .utf8),
                  let json = try? JSONDecoder().decode(PlanJSON.self, from: data) else { return }
            await bus.publish(
                BantiEvent(source: id, topic: "motor.speech_plan", surprise: 0,
                           payload: .speechPlan(SpeechPlanPayload(sentences: json.sentences))),
                topic: "motor.speech_plan"
            )
        } catch {
            await bus.publish(
                BantiEvent(source: id, topic: "motor.speech_plan", surprise: 0,
                           payload: .speechPlan(SpeechPlanPayload(sentences: []))),
                topic: "motor.speech_plan"
            )
        }
    }

    private struct PlanJSON: Codable { let sentences: [String] }
}
