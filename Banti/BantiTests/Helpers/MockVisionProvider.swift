import Foundation
@testable import Banti

struct MockVisionProvider: VisionProvider {
    let result: Result<String, Error>
    // Optional callback invoked when describe() is called — use to synchronize tests.
    let onCall: (@Sendable () -> Void)?

    init(returning description: String, onCall: (@Sendable () -> Void)? = nil) {
        self.result = .success(description)
        self.onCall = onCall
    }

    init(throwing error: Error, onCall: (@Sendable () -> Void)? = nil) {
        self.result = .failure(error)
        self.onCall = onCall
    }

    func describe(jpeg: Data, prompt: String) async throws -> String {
        onCall?()
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}
