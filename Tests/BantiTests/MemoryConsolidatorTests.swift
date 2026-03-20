// Tests/BantiTests/MemoryConsolidatorTests.swift
import XCTest
@testable import BantiCore

final class MemoryConsolidatorTests: XCTestCase {

    func testStoresHighValueEpisode() async throws {
        let bus = EventBus()
        let storedEpisodes = ActorBox<[String]>([])

        let consolidator = MemoryConsolidator(
            cerebras: { _, _, _, _ in "{\"store\":true,\"reason\":\"meaningful interaction\"}" },
            storeSidecar: { episode in await storedEpisodes.appendString(episode) }
        )
        await consolidator.start(bus: bus)

        let ep = EpisodePayload(text: "Pavan fixed the bug!", participants: ["Pavan"], emotionalTone: "happy")
        await bus.publish(
            BantiEvent(source: "temporal_binder", topic: "episode.bound", surprise: 1.0,
                       payload: .episodeBound(ep)),
            topic: "episode.bound"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        let stored = await storedEpisodes.value
        XCTAssertEqual(stored.count, 1)
    }

    func testSkipsLowValueEpisode() async {
        let bus = EventBus()
        let storedEpisodes = ActorBox<[String]>([])

        let consolidator = MemoryConsolidator(
            cerebras: { _, _, _, _ in "{\"store\":false,\"reason\":\"not significant\"}" },
            storeSidecar: { episode in await storedEpisodes.appendString(episode) }
        )
        await consolidator.start(bus: bus)

        let ep = EpisodePayload(text: "nothing happened", participants: [], emotionalTone: "neutral")
        await bus.publish(
            BantiEvent(source: "temporal_binder", topic: "episode.bound", surprise: 0.1,
                       payload: .episodeBound(ep)),
            topic: "episode.bound"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        let stored = await storedEpisodes.value
        XCTAssertEqual(stored.count, 0, "low-value episode should not be stored")
    }
}
