import Foundation
import os

actor EventHubActor {
    private let logger = Logger(subsystem: "com.banti.core", category: "EventHub")
    private let maxQueueSize: Int

    private struct Subscription {
        let queue: BoundedEventQueue
    }

    private var subscriptions: [ObjectIdentifier: [SubscriptionID: Subscription]] = [:]

    init(maxQueueSize: Int = 500) {
        self.maxQueueSize = maxQueueSize
    }

    func publish<E: PerceptionEvent>(_ event: E) async {
        let typeKey = ObjectIdentifier(E.self)
        guard let subs = subscriptions[typeKey] else { return }
        for (_, sub) in subs {
            sub.queue.enqueue(event)
        }
    }

    @discardableResult
    func subscribe<E: PerceptionEvent>(
        _ type: E.Type,
        handler: @escaping @Sendable (E) async -> Void
    ) -> SubscriptionID {
        let subID = SubscriptionID()
        let typeKey = ObjectIdentifier(E.self)
        let queue = BoundedEventQueue(maxSize: maxQueueSize)

        let sub = Subscription(queue: queue)

        if subscriptions[typeKey] == nil {
            subscriptions[typeKey] = [:]
        }
        subscriptions[typeKey]?[subID] = sub

        Task {
            for await event in queue.stream {
                if let typed = event as? E {
                    await handler(typed)
                }
            }
        }

        return subID
    }

    func unsubscribe(_ id: SubscriptionID) {
        for typeKey in subscriptions.keys {
            if let sub = subscriptions[typeKey]?[id] {
                sub.queue.finish()
                subscriptions[typeKey]?.removeValue(forKey: id)
            }
        }
    }
}

final class BoundedEventQueue: @unchecked Sendable {
    private var continuation: AsyncStream<any PerceptionEvent>.Continuation?
    let stream: AsyncStream<any PerceptionEvent>

    init(maxSize: Int) {
        var cont: AsyncStream<any PerceptionEvent>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(maxSize)) { cont = $0 }
        self.continuation = cont
    }

    func enqueue(_ event: any PerceptionEvent) {
        continuation?.yield(event)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}
