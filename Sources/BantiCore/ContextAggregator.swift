// Sources/BantiCore/ContextAggregator.swift
import Foundation

/// Subscribes to all sensor.* events and maintains last-known state for snapshotJSON().
/// Phase 1: parallel to PerceptionContext.
/// Phase 2: replaces PerceptionContext as the sole source of truth for the sidecar.
/// Phase 3: deleted when SelfModel migrates to episode.bound events.
public actor ContextAggregator: CorticalNode {
    public let id = "context_aggregator"
    public let subscribedTopics = ["sensor.*"]

    private var lastFace: FacePayload?
    private var lastScreen: ScreenPayload?
    private var lastEmotionFace: EmotionPayload?
    private var lastEmotionVoice: EmotionPayload?
    private var lastSpeech: SpeechPayload?
    private var lastSound: SoundPayload?

    public init() {}

    public func start(bus: EventBus) async {
        await bus.subscribe(topic: "sensor.*") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        switch event.payload {
        case .faceUpdate(let p):    lastFace = p
        case .screenUpdate(let p):  lastScreen = p
        case .emotionUpdate(let p):
            if p.source == "hume_face" { lastEmotionFace = p }
            else { lastEmotionVoice = p }
        case .speechDetected(let p): lastSpeech = p
        case .soundUpdate(let p):   lastSound = p
        default: break
        }
    }

    /// Returns a compact JSON snapshot of last-known state.
    /// Mirrors the format previously produced by PerceptionContext.snapshotJSON().
    public func snapshotJSON() -> String {
        var dict: [String: Any] = [:]
        if let f = lastFace {
            dict["face"] = ["personID": f.personID as Any,
                            "personName": f.personName as Any,
                            "confidence": f.confidence]
        }
        if let s = lastScreen {
            dict["screen"] = ["ocrLines": s.ocrLines, "interpretation": s.interpretation]
        }
        if let e = lastEmotionFace {
            dict["emotion"] = e.emotions.map { ["label": $0.label, "score": $0.score] }
        }
        if let e = lastEmotionVoice {
            dict["voiceEmotion"] = e.emotions.map { ["label": $0.label, "score": $0.score] }
        }
        if let sp = lastSpeech {
            dict["speech"] = ["transcript": sp.transcript, "speakerID": sp.speakerID as Any]
        }
        if let so = lastSound {
            dict["sound"] = ["label": so.label, "confidence": so.confidence]
        }
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
