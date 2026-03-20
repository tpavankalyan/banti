// Sources/BantiCore/CorticalNode.swift
import Foundation

/// Every node in the cortical graph implements this protocol.
/// Sensor cortices are publishers only — their `subscribedTopics` is empty.
/// Gate, brain, memory, and motor nodes subscribe and publish.
public protocol CorticalNode: Actor {
    /// Unique identifier for this node, used in event `source` field.
    var id: String { get }

    /// Topics this node listens to. Empty for sensor cortices.
    var subscribedTopics: [String] { get }

    /// Register subscriptions and begin the node's internal loop.
    func start(bus: EventBus) async

    /// Process an incoming event. Implementations call `bus.publish()` for outputs.
    func handle(_ event: BantiEvent) async
}
