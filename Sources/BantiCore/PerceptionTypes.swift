// Sources/BantiCore/PerceptionTypes.swift
import Foundation
import Vision
import CoreGraphics

// MARK: - Frame processor protocol (replaces LocalVision dependency in captures)

public protocol FrameProcessor {
    func process(jpegData: Data, source: String)
}

// MARK: - Events emitted by LocalPerception after Apple Vision analysis

public enum PerceptionEvent {
    case faceDetected(observation: VNFaceObservation)
    case bodyPoseDetected(observation: VNHumanBodyPoseObservation)
    case handPoseDetected(observation: VNHumanHandPoseObservation)
    case humanPresent
    case textRecognized(lines: [String])   // confidence >= 0.5, top-to-bottom
    case sceneClassified(labels: [(identifier: String, confidence: Float)])
    case nothingDetected
}

// MARK: - State types (one per modality, all Codable for snapshot logging)

public struct FaceState: Codable {
    public let boundingBox: CodableCGRect
    public let landmarksDetected: Bool
    public let updatedAt: Date

    public init(boundingBox: CGRect, landmarksDetected: Bool, updatedAt: Date) {
        self.boundingBox = CodableCGRect(boundingBox)
        self.landmarksDetected = landmarksDetected
        self.updatedAt = updatedAt
    }
}

public struct EmotionState: Codable {
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

public struct PoseState: Codable {
    public let bodyPoints: [String: CodableCGPoint]
    public let handPoints: [String: CodableCGPoint]?
    public let updatedAt: Date

    public init(bodyPoints: [String: CGPoint], handPoints: [String: CGPoint]?, updatedAt: Date) {
        self.bodyPoints = bodyPoints.mapValues { CodableCGPoint($0) }
        self.handPoints = handPoints?.mapValues { CodableCGPoint($0) }
        self.updatedAt = updatedAt
    }
}

public struct GestureState: Codable {
    public let description: String
    public let updatedAt: Date
    public init(description: String, updatedAt: Date) {
        self.description = description
        self.updatedAt = updatedAt
    }
}

public struct ScreenState: Codable {
    public let ocrLines: [String]
    public let interpretation: String
    public let updatedAt: Date
    public init(ocrLines: [String], interpretation: String, updatedAt: Date) {
        self.ocrLines = ocrLines
        self.interpretation = interpretation
        self.updatedAt = updatedAt
    }
}

public struct ActivityState: Codable {
    public let description: String
    public let updatedAt: Date
    public init(description: String, updatedAt: Date) {
        self.description = description
        self.updatedAt = updatedAt
    }
}

// MARK: - Observation envelope (returned by all cloud analyzers)

public enum PerceptionObservation {
    case face(FaceState)
    case pose(PoseState)
    case emotion(EmotionState)
    case activity(ActivityState)
    case gesture(GestureState)
    case screen(ScreenState)
    case speech(SpeechState)
    case voiceEmotion(VoiceEmotionState)
    case sound(SoundState)
}

// MARK: - Cloud analyzer protocol

public protocol CloudAnalyzer {
    /// jpegData is nil for text-only analyzers (GPT4oScreenAnalyzer).
    /// Image-requiring analyzers return nil when jpegData is nil.
    func analyze(jpegData: Data?, events: [PerceptionEvent]) async -> PerceptionObservation?
}

// MARK: - Perception dispatcher protocol (breaks forward dependency between LocalPerception and PerceptionRouter)

public protocol PerceptionDispatcher: AnyObject {
    func dispatch(jpegData: Data, source: String, events: [PerceptionEvent]) async
}

// MARK: - Codable helpers for CGRect / CGPoint

public struct CodableCGRect: Codable {
    public let x, y, width, height: Double
    public init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; width = r.width; height = r.height }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct CodableCGPoint: Codable {
    public let x, y: Double
    public init(_ p: CGPoint) { x = p.x; y = p.y }
}
