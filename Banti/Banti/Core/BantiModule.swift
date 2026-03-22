import Foundation

struct ModuleID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    var description: String { rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

struct Capability: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }

    static let audioCapture = Capability("audio-capture")
    static let transcription = Capability("transcription")
    static let diarization = Capability("diarization")
    static let projection = Capability("projection")
    static let reasoning = Capability("reasoning")
    static let speech = Capability("speech")
    static let videoCapture      = Capability("video-capture")
    static let sceneDescription  = Capability("scene-description")
    static let screenCapture     = Capability("screen-capture")
    static let screenDescription = Capability("screen-description")
    static let activeAppTracking = Capability("active-app-tracking")
    static let axObservation     = Capability("ax-observation")
    static let sceneChangeDetection = Capability("scene-change-detection")
}

enum ModuleHealth: Sendable {
    case healthy
    case degraded(reason: String)
    case failed(error: any Error)

    var label: String {
        switch self {
        case .healthy: "healthy"
        case .degraded(let r): "degraded:\(r)"
        case .failed: "failed"
        }
    }
}

enum RestartPolicy: Sendable {
    case never
    case onFailure(maxRetries: Int, backoff: TimeInterval)
    case always
}

protocol BantiModule: Actor {
    nonisolated var id: ModuleID { get }
    nonisolated var capabilities: Set<Capability> { get }
    func start() async throws
    func stop() async
    func health() async -> ModuleHealth
}
