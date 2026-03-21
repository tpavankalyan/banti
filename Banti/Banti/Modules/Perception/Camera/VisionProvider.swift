import Foundation

// MARK: - VisionProvider

protocol VisionProvider: Sendable {
    func describe(jpeg: Data, prompt: String) async throws -> String
}

// MARK: - VisionError

struct VisionError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
