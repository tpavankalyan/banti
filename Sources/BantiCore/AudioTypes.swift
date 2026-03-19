// Sources/BantiCore/AudioTypes.swift
import Foundation

// MARK: - Dispatcher protocol (MicrophoneCapture depends on this, not the concrete actor)
// Sendable required: AVAudioEngine tap calls dispatch() from an audio thread outside any actor.
public protocol AudioChunkDispatcher: AnyObject, Sendable {
    func dispatch(pcmChunk: Data) async   // 16kHz mono Int16 linear16
}

// MARK: - Events (internal to AudioRouter)

public enum AudioEvent {
    case speechTranscribed(text: String, speakerID: Int?, isFinal: Bool, confidence: Float)
    case voiceEmotionDetected(emotions: [(label: String, score: Float)])
    case soundClassified(label: String, confidence: Float)
    case silence
}

// MARK: - State types (all Codable — required for PerceptionContext.snapshotJSON())

public struct SpeechState: Codable {
    public let transcript: String
    public let speakerID: Int?
    public let isFinal: Bool
    public let confidence: Float
    public let updatedAt: Date

    public init(transcript: String, speakerID: Int?, isFinal: Bool, confidence: Float, updatedAt: Date) {
        self.transcript = transcript
        self.speakerID = speakerID
        self.isFinal = isFinal
        self.confidence = confidence
        self.updatedAt = updatedAt
    }
}

public struct VoiceEmotionState: Codable {
    public struct Emotion: Codable {
        public let label: String
        public let score: Float
    }
    public let emotions: [Emotion]
    public let updatedAt: Date

    public init(emotions: [(label: String, score: Float)], updatedAt: Date) {
        self.emotions = emotions.map { Emotion(label: $0.label, score: $0.score) }
        self.updatedAt = updatedAt
    }
}

public struct SoundState: Codable {
    public let label: String
    public let confidence: Float
    public let updatedAt: Date

    public init(label: String, confidence: Float, updatedAt: Date) {
        self.label = label
        self.confidence = confidence
        self.updatedAt = updatedAt
    }
}
