import XCTest
@testable import Banti

final class ClaudeVisionProviderTests: XCTestCase {
    func testInitializesWithApiKeyAndDefaultModel() {
        let provider = ClaudeVisionProvider(apiKey: "test-key")
        // Compiles means the type exists and conforms to VisionProvider.
        let _: any VisionProvider = provider
    }

    func testInitializesWithCustomModel() {
        let provider = ClaudeVisionProvider(apiKey: "test-key", model: "claude-opus-4-6")
        let _: any VisionProvider = provider
        XCTAssertEqual(provider.model, "claude-opus-4-6")
    }
}
