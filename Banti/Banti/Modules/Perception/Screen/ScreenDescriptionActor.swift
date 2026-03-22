import Foundation
import os

actor ScreenDescriptionActor: BantiModule {
    nonisolated let id = ModuleID("screen-description")
    nonisolated let capabilities: Set<Capability> = [.screenDescription]

    private let logger = Logger(subsystem: "com.banti.screen-description", category: "Screen")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let overrideProvider: (any VisionProvider)?

    private var subscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy
    private var describedCount = 0

    init(eventHub: EventHubActor, config: ConfigActor, provider: (any VisionProvider)? = nil) {
        self.eventHub = eventHub
        self.config = config
        self.overrideProvider = provider
    }

    func start() async throws {
        let provider = try await buildProvider()

        let prompt = (await config.value(for: EnvKey.screenDescriptionPrompt))
            ?? "Describe what is shown on this computer screen. Focus on the application in use, visible text, open documents, and what the user appears to be doing."

        subscriptionID = await eventHub.subscribe(ScreenChangeEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleChange(event, provider: provider, prompt: prompt)
        }

        _health = .healthy
        logger.notice("ScreenDescriptionActor started (change-driven)")
    }

    func stop() async {
        if let id = subscriptionID {
            await eventHub.unsubscribe(id)
            subscriptionID = nil
        }
    }

    func health() async -> ModuleHealth { _health }

    private func handleChange(
        _ event: ScreenChangeEvent,
        provider: any VisionProvider,
        prompt: String
    ) async {
        let captureTime = event.captureTime

        do {
            let description = try await provider.describe(jpeg: event.jpeg, prompt: prompt)
            let responseTime = Date()

            describedCount += 1
            _health = .healthy

            let screenEvent = ScreenDescriptionEvent(
                text: description,
                captureTime: captureTime,
                responseTime: responseTime,
                changeDistance: event.changeDistance
            )
            await eventHub.publish(screenEvent)

            if describedCount == 1 || describedCount.isMultiple(of: 10) {
                logger.notice("Published screen desc #\(self.describedCount): \(description.prefix(60), privacy: .public)")
            }
        } catch {
            logger.error("VisionProvider error: \(error.localizedDescription, privacy: .public)")
            _health = .degraded(reason: "VLM call failed: \(error.localizedDescription)")
        }
    }

    private func buildProvider() async throws -> any VisionProvider {
        if let override = overrideProvider { return override }

        let selected = ((await config.value(for: EnvKey.visionProvider)) ?? "claude")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch selected {
        case "claude":
            let key = try await config.require(EnvKey.anthropicAPIKey)
            let model = (await config.value(for: EnvKey.anthropicVisionModel)) ?? ClaudeVisionProvider.defaultModel
            logger.notice("Screen vision using Claude (\(model, privacy: .public))")
            return ClaudeVisionProvider(apiKey: key, model: model)

        default:
            throw VisionError("Unknown VISION_PROVIDER: \(selected). Supported: claude")
        }
    }
}
