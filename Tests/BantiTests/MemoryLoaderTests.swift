// Tests/BantiTests/MemoryLoaderTests.swift
import XCTest
@testable import BantiCore

final class MemoryLoaderTests: XCTestCase {

    func testPublishesMemoryRetrievedOnFaceWithPerson() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "memory.retrieve") { event in
            await received.append(event)
        }

        let loader = MemoryLoader(querySidecar: { personID in
            MemoryRetrievedPayload(personID: personID, personName: "Pavan",
                                   facts: ["likes chai", "works on banti"])
        })
        await loader.start(bus: bus)

        let face = FacePayload(boundingBox: CodableCGRect(CGRect.zero), personID: "p1",
                               personName: "Pavan", confidence: 0.9)
        await bus.publish(
            BantiEvent(source: "visual_cortex", topic: "sensor.visual", surprise: 0.6,
                       payload: .faceUpdate(face)),
            topic: "sensor.visual"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .memoryRetrieved(let m) = events.first?.payload {
            XCTAssertEqual(m.personID, "p1")
            XCTAssertTrue(m.facts.contains("likes chai"))
        } else { XCTFail() }
    }

    func testIgnoresFaceWithoutPersonID() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "memory.retrieve") { event in
            await received.append(event)
        }

        let loader = MemoryLoader(querySidecar: { _ in
            MemoryRetrievedPayload(personID: "x", personName: nil, facts: [])
        })
        await loader.start(bus: bus)

        // Face without personID
        let face = FacePayload(boundingBox: CodableCGRect(CGRect.zero), personID: nil,
                               personName: nil, confidence: 0.9)
        await bus.publish(
            BantiEvent(source: "visual_cortex", topic: "sensor.visual", surprise: 0.6,
                       payload: .faceUpdate(face)),
            topic: "sensor.visual"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        let noEvents = await received.value
        XCTAssertEqual(noEvents.count, 0, "should not query for face without personID")
    }
}
