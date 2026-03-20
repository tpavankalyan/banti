import XCTest
@testable import BantiCore

final class PrefrontalNodeTests: XCTestCase {
    func testUsesSupportedModelWhenResponding() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        let capturedModels = ModelCapture()
        _ = await bus.subscribe(topic: "brain.prefrontal.response") { event in
            await received.append(event)
        }

        let node = PrefrontalNode(cerebras: { model, _, _, _ in
            await capturedModels.record(model)
            return "I can help think this through."
        })
        await node.start(bus: bus)

        let episode = EpisodePayload(
            text: "She looks uncertain.",
            participants: ["friend"],
            emotionalTone: "concern"
        )
        let route = BrainRoutePayload(tracks: ["prefrontal"], reason: "needs reasoning", episode: episode)
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )

        try? await Task.sleep(nanoseconds: 100_000_000)

        let models = await capturedModels.values
        XCTAssertEqual(models, ["llama3.1-8b"])
        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .brainResponse(let response) = events.first?.payload {
            XCTAssertEqual(response.track, "prefrontal")
            XCTAssertEqual(response.text, "I can help think this through.")
        } else {
            XCTFail("expected a prefrontal brain response")
        }
    }
}

private actor ModelCapture {
    private(set) var values: [String] = []

    func record(_ model: String) {
        values.append(model)
    }
}
