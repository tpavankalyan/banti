// Sources/BantiCore/ResponseArbitrator.swift
import Foundation

public actor ResponseArbitrator: CorticalNode {
    public let id = "response_arbitrator"
    public let subscribedTopics = ["brain.route", "brain.brainstem.response",
                                    "brain.limbic.response", "brain.prefrontal.response"]

    private let cerebras: CerebrasCompletion
    private let collectionWindowNs: UInt64
    private var _bus: EventBus?

    // Per-route collection state, keyed by episode ID so overlapping routes cannot mix.
    private struct PendingRouteState {
        var activatedTracks: [String]
        var responsesByTrack: [String: BrainResponsePayload]
        var windowTask: Task<Void, Never>?
    }

    private var pendingRoutes: [UUID: PendingRouteState] = [:]
    private var currentEpisodeID: UUID?
    private var retiredEpisodeIDs: Set<UUID> = []
    private var latestRouteTimestampNs: UInt64 = 0

    private static let defaultSystemPrompt = """
    You are banti's response arbitrator. Given candidate responses from different brain tracks,
    produce an ordered list of sentences to speak. Suppress redundant content. Merge where natural.
    Prefer empathy before information. Output JSON only: {"sentences":["<s1>","<s2>",...]}
    If nothing is worth saying, return: {"sentences":[]}
    """
    private var systemPrompt: String = ResponseArbitrator.defaultSystemPrompt

    public func setSystemPrompt(_ prompt: String) async {
        systemPrompt = prompt
    }

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
            if retiredEpisodeIDs.contains(route.episode.episodeID) {
                return
            }
            if route.episode.timestampNs < latestRouteTimestampNs,
               currentEpisodeID != route.episode.episodeID {
                return
            }
            latestRouteTimestampNs = max(latestRouteTimestampNs, route.episode.timestampNs)
            currentEpisodeID = route.episode.episodeID
            discardPendingRoutes(except: route.episode.episodeID)
            await upsertRouteState(
                episodeID: route.episode.episodeID,
                activatedTracks: route.tracks,
                incomingResponse: nil,
                resetWindow: true
            )
        case .brainResponse(let response):
            if retiredEpisodeIDs.contains(response.episodeID) {
                return
            }
            if let currentEpisodeID, response.episodeID != currentEpisodeID {
                return
            }
            if currentEpisodeID == nil {
                currentEpisodeID = response.episodeID
                discardPendingRoutes(except: response.episodeID)
            }
            let state = await upsertRouteState(
                episodeID: response.episodeID,
                activatedTracks: response.activatedTracks,
                incomingResponse: response,
                resetWindow: false
            )
            let respondedTracks = Set(state.responsesByTrack.keys)
            let expectedTracks = Set(state.activatedTracks)
            if !expectedTracks.isEmpty && respondedTracks.isSuperset(of: expectedTracks) {
                state.windowTask?.cancel()
                await flush(episodeID: response.episodeID)
            }
        default:
            break
        }
    }

    private func discardPendingRoutes(except episodeID: UUID) {
        let staleEpisodeIDs = pendingRoutes.keys.filter { $0 != episodeID }
        for pendingEpisodeID in staleEpisodeIDs {
            pendingRoutes[pendingEpisodeID]?.windowTask?.cancel()
            pendingRoutes.removeValue(forKey: pendingEpisodeID)
            retiredEpisodeIDs.insert(pendingEpisodeID)
        }
    }

    @discardableResult
    private func upsertRouteState(
        episodeID: UUID,
        activatedTracks: [String],
        incomingResponse: BrainResponsePayload?,
        resetWindow: Bool
    ) async -> PendingRouteState {
        var state = pendingRoutes[episodeID] ?? PendingRouteState(
            activatedTracks: activatedTracks,
            responsesByTrack: [:],
            windowTask: nil
        )

        if !activatedTracks.isEmpty {
            state.activatedTracks = activatedTracks
        }
        if let response = incomingResponse {
            state.responsesByTrack[response.track] = response
        }
        if resetWindow || state.windowTask == nil {
            state.windowTask?.cancel()
            state.windowTask = scheduleWindow(for: episodeID)
        }
        pendingRoutes[episodeID] = state
        return state
    }

    private func scheduleWindow(for episodeID: UUID) -> Task<Void, Never> {
        let ns = collectionWindowNs
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            Task { [weak self] in await self?.flush(episodeID: episodeID) }
        }
    }

    private func flush(episodeID: UUID) async {
        guard let bus = _bus,
              let state = pendingRoutes.removeValue(forKey: episodeID) else { return }
        state.windowTask?.cancel()
        retiredEpisodeIDs.insert(episodeID)
        if currentEpisodeID == episodeID {
            currentEpisodeID = nil
        }

        let collectedResponses = Array(state.responsesByTrack.values)
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
            .sorted { $0.track < $1.track }
            .map { "[\($0.track)]: \($0.text)" }
            .joined(separator: "\n")

        do {
            let response = try await cerebras("llama3.1-8b", systemPrompt, candidateText, 150)
            guard let json = LLMJSON.decode(PlanJSON.self, from: response) else { return }
            await bus.publish(
                BantiEvent(source: id, topic: "motor.speech_plan", surprise: 0,
                           payload: .speechPlan(SpeechPlanPayload(sentences: json.sentences))),
                topic: "motor.speech_plan"
            )
        } catch {
            print("[banti:response_arbitrator] cerebras error: \(error)")
            await bus.publish(
                BantiEvent(source: id, topic: "motor.speech_plan", surprise: 0,
                           payload: .speechPlan(SpeechPlanPayload(sentences: []))),
                topic: "motor.speech_plan"
            )
        }
    }

    private struct PlanJSON: Codable { let sentences: [String] }
}
