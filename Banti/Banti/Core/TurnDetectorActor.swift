import Foundation

/// Watches TranscriptSegmentEvents and publishes TurnEndedEvent after
/// `silenceDuration` seconds of silence following a final segment.
actor TurnDetectorActor: BantiModule {
    nonisolated let id = ModuleID("turn-detector")
    nonisolated let capabilities: Set<Capability> = []

    private let eventHub: EventHubActor
    private let silenceDuration: TimeInterval
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy

    private var pendingTexts: [String] = []
    private var silenceTask: Task<Void, Never>?

    init(eventHub: EventHubActor, silenceDuration: TimeInterval = 1.5) {
        self.eventHub = eventHub
        self.silenceDuration = silenceDuration
    }

    func start() async throws {
        subscriptionIDs.append(await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] event in
            await self?.handle(event)
        })
        _health = .healthy
    }

    func stop() async {
        silenceTask?.cancel()
        silenceTask = nil
        pendingTexts.removeAll()
        for subID in subscriptionIDs {
            await eventHub.unsubscribe(subID)
        }
        subscriptionIDs.removeAll()
    }

    func health() async -> ModuleHealth { _health }

    // MARK: - Private

    private func handle(_ event: TranscriptSegmentEvent) {
        let wasEmpty = pendingTexts.isEmpty

        // Cancel any running silence timer — user is still speaking
        silenceTask?.cancel()
        silenceTask = nil

        if event.isFinal && !event.text.isEmpty {
            pendingTexts.append(event.text)
            if wasEmpty {
                Task { await self.eventHub.publish(TurnStartedEvent()) }
            }
        }

        guard !pendingTexts.isEmpty else { return }

        // (Re)start the silence timer
        silenceTask = Task { [self] in
            do {
                try await Task.sleep(for: .seconds(silenceDuration))
            } catch {
                return  // Cancelled — a new segment arrived
            }
            guard !Task.isCancelled else { return }
            await fireTurn()
        }
    }

    private func fireTurn() async {
        let text = pendingTexts.joined(separator: " ")
        pendingTexts.removeAll()
        silenceTask = nil
        await eventHub.publish(TurnEndedEvent(text: text))
    }
}
