// Sources/BantiCore/EventBus.swift
import Foundation

public typealias SubscriptionID = UUID

public actor EventBus {
    private var subscribers: [String: [(SubscriptionID, @Sendable (BantiEvent) async -> Void)]] = [:]

    public init() {}

    @discardableResult
    public func subscribe(
        topic: String,
        handler: @escaping @Sendable (BantiEvent) async -> Void
    ) -> SubscriptionID {
        let id = SubscriptionID()
        subscribers[topic, default: []].append((id, handler))
        return id
    }

    public func unsubscribe(_ id: SubscriptionID) {
        for key in subscribers.keys {
            subscribers[key]?.removeAll { $0.0 == id }
        }
    }

    public func publish(_ event: BantiEvent, topic: String) {
        for (pattern, handlers) in subscribers {
            guard topicMatches(topic, pattern: pattern) else { continue }
            for (_, handler) in handlers {
                let h = handler
                let e = event
                Task { await h(e) }
            }
        }
    }

    // MARK: - Internal (exposed for tests via @testable)

    func subscriberCount(for topic: String) -> Int {
        subscribers[topic]?.count ?? 0
    }

    // MARK: - Private

    private func topicMatches(_ topic: String, pattern: String) -> Bool {
        if pattern == "*" { return true }
        if pattern == topic { return true }
        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            return topic.hasPrefix(prefix + ".")
        }
        return false
    }
}
