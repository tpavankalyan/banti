import XCTest
@testable import Banti

// Smoke tests — verify ClaudeVisionProvider compiles and conforms to VisionProvider.
// TODO: Add URLProtocol-based integration tests covering the describe() network path.
final class ClaudeVisionProviderTests: XCTestCase {
    func testInitializesWithApiKeyAndDefaultModel() {
        let provider = ClaudeVisionProvider(apiKey: "test-key")
        // Compiles means the type exists and conforms to VisionProvider.
        let _: any VisionProvider = provider
    }

    func testInitializesWithCustomModel() {
        let provider = ClaudeVisionProvider(apiKey: "test-key", model: "claude-opus-4-6")
        let _: any VisionProvider = provider
    }
}
