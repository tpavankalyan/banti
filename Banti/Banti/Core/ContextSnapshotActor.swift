import Foundation

/// Immutable snapshot of the agent's current perception context.
/// Produced by `ContextSnapshotActor` and passed to the LLM bridge.
struct ContextSnapshot {
    let activeApp: ActiveAppEvent?
    let axFocus: AXFocusEvent?
    let sceneDescription: SceneDescriptionEvent?
    let screenDescription: ScreenDescriptionEvent?
    /// Up to 5 most recent *final* transcript segments, oldest first.
    let recentTranscripts: [TranscriptSegmentEvent]

    /// Formats the snapshot as a labeled text block suitable for an LLM system prompt.
    func formatted() -> String {
        var lines: [String] = ["=== Current Context ==="]

        if let app = activeApp {
            lines.append("[Active App] \(app.appName) (\(app.bundleIdentifier))")
        }

        if let ax = axFocus {
            var focusLine = "[Focus] \(ax.appName) — \(ax.elementRole)"
            if let title = ax.elementTitle { focusLine += " \"\(title)\"" }
            if let selected = ax.selectedText, !selected.isEmpty {
                focusLine += " | selected: \"\(selected.prefix(120))\""
            }
            lines.append(focusLine)
        }

        if let scene = sceneDescription {
            lines.append("[Camera] \(scene.text)")
        }

        if let screen = screenDescription {
            lines.append("[Screen] \(screen.text)")
        }

        if !recentTranscripts.isEmpty {
            lines.append("[Transcript]")
            for segment in recentTranscripts {
                lines.append("  \(segment.speakerLabel): \(segment.text)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

/// Subscribes to all perception events and maintains a live context snapshot.
/// Other modules (e.g. the LLM bridge) call `snapshot()` to read the current state.
actor ContextSnapshotActor: BantiModule {
    nonisolated let id = ModuleID("context-snapshot")
    nonisolated let capabilities: Set<Capability> = []

    private let eventHub: EventHubActor
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy

    private var latestActiveApp: ActiveAppEvent?
    private var latestAXFocus: AXFocusEvent?
    private var latestSceneDescription: SceneDescriptionEvent?
    private var latestScreenDescription: ScreenDescriptionEvent?
    private var recentTranscripts: [TranscriptSegmentEvent] = []

    static let maxTranscripts = 5

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    func start() async throws {
        subscriptionIDs.append(await eventHub.subscribe(ActiveAppEvent.self) { [weak self] event in
            await self?.handle(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(AXFocusEvent.self) { [weak self] event in
            await self?.handle(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(SceneDescriptionEvent.self) { [weak self] event in
            await self?.handle(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(ScreenDescriptionEvent.self) { [weak self] event in
            await self?.handle(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] event in
            await self?.handle(event)
        })
        _health = .healthy
    }

    func stop() async {
        for subID in subscriptionIDs {
            await eventHub.unsubscribe(subID)
        }
        subscriptionIDs.removeAll()
    }

    func health() async -> ModuleHealth { _health }

    func snapshot() -> ContextSnapshot {
        ContextSnapshot(
            activeApp: latestActiveApp,
            axFocus: latestAXFocus,
            sceneDescription: latestSceneDescription,
            screenDescription: latestScreenDescription,
            recentTranscripts: recentTranscripts
        )
    }

    // MARK: - Private handlers

    private func handle(_ event: ActiveAppEvent) {
        latestActiveApp = event
    }

    private func handle(_ event: AXFocusEvent) {
        latestAXFocus = event
    }

    private func handle(_ event: SceneDescriptionEvent) {
        latestSceneDescription = event
    }

    private func handle(_ event: ScreenDescriptionEvent) {
        latestScreenDescription = event
    }

    private func handle(_ event: TranscriptSegmentEvent) {
        guard event.isFinal else { return }
        recentTranscripts.append(event)
        if recentTranscripts.count > Self.maxTranscripts {
            recentTranscripts.removeFirst(recentTranscripts.count - Self.maxTranscripts)
        }
    }
}
