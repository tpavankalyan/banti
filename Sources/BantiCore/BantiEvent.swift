// Sources/BantiCore/BantiEvent.swift
import Foundation

// MARK: - Envelope

public struct BantiEvent: Codable, Sendable {
    public let id: UUID
    public let source: String
    public let topic: String
    /// Monotonic nanoseconds since system boot (via `BantiClock.nowNs()`).
    /// Used for intra-session event ordering only.
    /// Do NOT use for cross-session or persistent storage timestamps.
    public let timestampNs: UInt64
    public let surprise: Float
    public let payload: EventPayload

    public init(
        id: UUID = UUID(),
        source: String,
        topic: String,
        timestampNs: UInt64 = BantiClock.nowNs(),
        surprise: Float,
        payload: EventPayload
    ) {
        self.id = id
        self.source = source
        self.topic = topic
        self.timestampNs = timestampNs
        self.surprise = surprise
        self.payload = payload
    }
}

// MARK: - Payload enum

public enum EventPayload: Codable, Sendable {
    case speechDetected(SpeechPayload)
    case faceUpdate(FacePayload)
    case screenUpdate(ScreenPayload)
    case emotionUpdate(EmotionPayload)
    case soundUpdate(SoundPayload)
    case episodeBound(EpisodePayload)
    case brainResponse(BrainResponsePayload)
    case brainRoute(BrainRoutePayload)
    case voiceSpeaking(VoiceSpeakingPayload)
    case speechPlan(SpeechPlanPayload)
    case memoryRetrieved(MemoryRetrievedPayload)
    case memorySaved(MemorySavedPayload)
}

// MARK: - Phase 1 payload types (used in this phase)

public struct SpeechPayload: Codable, Sendable {
    public let transcript: String
    public let speakerID: String?
    public init(transcript: String, speakerID: String?) {
        self.transcript = transcript; self.speakerID = speakerID
    }
}

public struct FacePayload: Codable, Sendable {
    public let boundingBox: CodableCGRect
    public let personID: String?
    public let personName: String?
    public let confidence: Float
    public init(boundingBox: CodableCGRect, personID: String?, personName: String?, confidence: Float) {
        self.boundingBox = boundingBox; self.personID = personID
        self.personName = personName; self.confidence = confidence
    }
}

public struct ScreenPayload: Codable, Sendable {
    public let ocrLines: [String]
    public let interpretation: String
    public init(ocrLines: [String], interpretation: String) {
        self.ocrLines = ocrLines; self.interpretation = interpretation
    }
}

public struct EmotionPayload: Codable, Sendable {
    public struct Emotion: Codable, Sendable {
        public let label: String
        public let score: Float
        public init(label: String, score: Float) { self.label = label; self.score = score }
    }
    public let emotions: [Emotion]
    public let source: String  // "hume_face" | "hume_voice"
    public init(emotions: [Emotion], source: String) { self.emotions = emotions; self.source = source }
}

public struct SoundPayload: Codable, Sendable {
    public let label: String
    public let confidence: Float
    public init(label: String, confidence: Float) { self.label = label; self.confidence = confidence }
}

public struct VoiceSpeakingPayload: Codable, Sendable {
    public let speaking: Bool
    public let estimatedDurationMs: Int
    public let tailWindowMs: Int
    public let text: String?
    public init(speaking: Bool, estimatedDurationMs: Int, tailWindowMs: Int, text: String?) {
        self.speaking = speaking; self.estimatedDurationMs = estimatedDurationMs
        self.tailWindowMs = tailWindowMs; self.text = text
    }
}

// MARK: - Phase 2+ payload types (defined now for type stability, used in Phase 2)

public struct EpisodePayload: Codable, Sendable {
    public let episodeID: UUID
    public let text: String
    public let participants: [String]
    public let emotionalTone: String
    public let timestampNs: UInt64
    public init(
        episodeID: UUID = UUID(),
        text: String,
        participants: [String],
        emotionalTone: String,
        timestampNs: UInt64 = BantiClock.nowNs()
    ) {
        self.episodeID = episodeID
        self.text = text
        self.participants = participants
        self.emotionalTone = emotionalTone
        self.timestampNs = timestampNs
    }
}

public struct BrainRoutePayload: Codable, Sendable {
    public let tracks: [String]
    public let reason: String
    public let episode: EpisodePayload
    public init(tracks: [String], reason: String, episode: EpisodePayload) {
        self.tracks = tracks; self.reason = reason; self.episode = episode
    }
}

public struct BrainResponsePayload: Codable, Sendable {
    public let track: String
    public let text: String
    public let activatedTracks: [String]
    public init(track: String, text: String, activatedTracks: [String]) {
        self.track = track; self.text = text; self.activatedTracks = activatedTracks
    }
}

public struct SpeechPlanPayload: Codable, Sendable {
    public let sentences: [String]
    public init(sentences: [String]) { self.sentences = sentences }
}

public struct MemoryRetrievedPayload: Codable, Sendable {
    public let personID: String
    public let personName: String?
    public let facts: [String]
    public let retrievedAtNs: UInt64
    public init(
        personID: String,
        personName: String?,
        facts: [String],
        retrievedAtNs: UInt64 = BantiClock.nowNs()
    ) {
        self.personID = personID
        self.personName = personName
        self.facts = facts
        self.retrievedAtNs = retrievedAtNs
    }
}

public struct MemorySavedPayload: Codable, Sendable {
    public let episodeID: UUID
    public let stored: Bool
    public init(episodeID: UUID, stored: Bool) { self.episodeID = episodeID; self.stored = stored }
}
