import XCTest
@testable import Banti

final class ScreenChangeDetectionActorTests: XCTestCase {

    func testCapabilityIncludesScreenChangeDetection() {
        let actor = ScreenChangeDetectionActor(
            eventHub: EventHubActor(),
            config: ConfigActor(content: ""),
            differencer: MockScreenFrameDifferencer([nil])
        )
        XCTAssertTrue(actor.capabilities.contains(.screenChangeDetection))
    }
}
