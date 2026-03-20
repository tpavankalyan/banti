// Sources/BantiCore/MemoryLoader.swift
import Foundation

/// Typealias for the sidecar query function — injectable for tests.
public typealias SidecarQuery = @Sendable (_ personID: String) async -> MemoryRetrievedPayload

public actor MemoryLoader: CorticalNode {
    public let id = "memory_loader"
    public let subscribedTopics = ["sensor.visual"]

    private let querySidecar: SidecarQuery
    private var _bus: EventBus?

    // Throttle: one fetch per personID per 30 seconds
    private var lastFetched: [String: Date] = [:]

    public init(querySidecar: @escaping SidecarQuery) {
        self.querySidecar = querySidecar
    }

    public func start(bus: EventBus) async {
        _bus = bus
        await bus.subscribe(topic: "sensor.visual") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        guard case .faceUpdate(let face) = event.payload,
              let personID = face.personID,
              let bus = _bus else { return }

        // Throttle: skip if fetched within last 30 seconds
        if let last = lastFetched[personID], Date().timeIntervalSince(last) < 30 { return }
        lastFetched[personID] = Date()

        let memory = await querySidecar(personID)
        await bus.publish(
            BantiEvent(source: id, topic: "memory.retrieve", surprise: 0,
                       payload: .memoryRetrieved(memory)),
            topic: "memory.retrieve"
        )
    }
}
