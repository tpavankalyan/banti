import XCTest
@testable import Banti

final class StateRegistryActorTests: XCTestCase {
    func testUpdateAndRetrieveStatus() async {
        let registry = StateRegistryActor()
        let mid = ModuleID("test")
        await registry.update(mid, status: .healthy)
        let status = await registry.status(for: mid)
        XCTAssertEqual(status?.label, "healthy")
    }

    func testAllStatusesReturnsAll() async {
        let registry = StateRegistryActor()
        await registry.update(ModuleID("a"), status: .healthy)
        await registry.update(ModuleID("b"), status: .degraded(reason: "slow"))
        let all = await registry.allStatuses()
        XCTAssertEqual(all.count, 2)
    }

    func testLastErrorTracked() async {
        let registry = StateRegistryActor()
        let mid = ModuleID("err")
        let err = ConfigError(message: "boom")
        await registry.update(mid, status: .failed(error: err))
        let lastErr = await registry.lastError(for: mid)
        XCTAssertNotNil(lastErr)
    }

    func testMissingModuleReturnsNil() async {
        let registry = StateRegistryActor()
        let status = await registry.status(for: ModuleID("nonexistent"))
        XCTAssertNil(status)
    }
}
