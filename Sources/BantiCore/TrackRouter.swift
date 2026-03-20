// Sources/BantiCore/TrackRouter.swift
import Foundation

public actor TrackRouter: CorticalNode {
    public let id = "track_router"
    public let subscribedTopics = ["episode.bound", "sensor.visual"]

    private let cerebras: CerebrasCompletion
    private var _bus: EventBus?

    // Unknown-person tracking
    private var unknownPersonFirstSeen: Date?
    private var lastUnknownPersonRouted: Date?

    private static let defaultSystemPrompt = """
    Given this episode, decide which brain tracks to activate.
    Available tracks: brainstem (instant reflex), limbic (emotional), prefrontal (deep reasoning).
    Output JSON only: {"tracks":["<track>",...],"reason":"<brief>"}
    Activate brainstem for most situations. Add limbic when emotion is significant.
    Add prefrontal when memory, reasoning, or long-term context is needed.
    """
    private var systemPrompt: String = TrackRouter.defaultSystemPrompt

    public func setSystemPrompt(_ prompt: String) async {
        systemPrompt = prompt
    }

    public init(cerebras: @escaping CerebrasCompletion) {
        self.cerebras = cerebras
    }

    public func start(bus: EventBus) async {
        _bus = bus
        await bus.subscribe(topic: "episode.bound") { [weak self] event in
            await self?.handle(event)
        }
        await bus.subscribe(topic: "sensor.visual") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        switch event.payload {
        case .episodeBound(let episode):
            await routeEpisode(episode)
        case .faceUpdate(let face):
            await checkUnknownPerson(face: face)
        default:
            break
        }
    }

    private func routeEpisode(_ episode: EpisodePayload) async {
        guard let bus = _bus else { return }
        let userContent = "Episode: \(episode.text)\nTone: \(episode.emotionalTone)\nParticipants: \(episode.participants.joined(separator: ", "))"
        do {
            let response = try await cerebras("llama3.1-8b", systemPrompt, userContent, 60)
            guard let json = LLMJSON.decode(RouteJSON.self, from: response) else {
                print("[banti:track_router] bad JSON from cerebras: \(response)")
                return
            }
            let route = BrainRoutePayload(tracks: json.tracks, reason: json.reason, episode: episode)
            await bus.publish(
                BantiEvent(source: id, topic: "brain.route", surprise: 1.0,
                           payload: .brainRoute(route)),
                topic: "brain.route"
            )
        } catch {
            print("[banti:track_router] cerebras error: \(error)")
        }
    }

    private func checkUnknownPerson(face: FacePayload) async {
        guard let bus = _bus else { return }
        if face.personID != nil && face.personName == nil {
            if unknownPersonFirstSeen == nil { unknownPersonFirstSeen = Date() }
            if let firstSeen = unknownPersonFirstSeen,
               Date().timeIntervalSince(firstSeen) > 30,
               lastUnknownPersonRouted.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                lastUnknownPersonRouted = Date()
                let dummyEpisode = EpisodePayload(
                    text: "An unknown person has been present for over 30 seconds",
                    participants: [], emotionalTone: "neutral"
                )
                let route = BrainRoutePayload(tracks: ["brainstem"], reason: "unknown person greeting", episode: dummyEpisode)
                await bus.publish(
                    BantiEvent(source: id, topic: "brain.route", surprise: 0.8,
                               payload: .brainRoute(route)),
                    topic: "brain.route"
                )
            }
        } else {
            unknownPersonFirstSeen = nil
        }
    }

    private struct RouteJSON: Codable {
        let tracks: [String]
        let reason: String
    }
}
