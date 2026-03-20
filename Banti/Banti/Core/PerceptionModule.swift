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

protocol PerceptionModule: Actor {
    nonisolated var id: ModuleID { get }
    nonisolated var capabilities: Set<Capability> { get }
    func start() async throws
    func stop() async
    func health() async -> ModuleHealth
}
