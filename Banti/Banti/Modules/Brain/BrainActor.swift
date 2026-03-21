import Foundation
import os

struct BrainDecision: Sendable {
    let action: String
    let content: String
}

// Wraps a closure so tests can inject decision logic without a full provider.
private struct ClosureProvider: LLMProvider {
    let decide: @Sendable (String, String) async throws -> BrainDecision
    func decide(context: String, input: String) async throws -> BrainDecision {
        try await decide(context, input)
    }
}

actor BrainActor: BantiModule {
    nonisolated let id = ModuleID("brain")
    nonisolated let capabilities: Set<Capability> = [.reasoning]

    // Speaker label assigned to Banti's own voice by Deepgram diarization.
    // Brain ignores transcripts from this speaker — same as the human
    // efference-copy mechanism that prevents us reacting to our own voice.
    private static let selfSpeakerLabel = "Speaker 2"

    private let logger = Logger(subsystem: "com.banti.brain", category: "Brain")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let debounceDuration: Duration
    private let overrideProvider: (any LLMProvider)?

    private var transcriptSubscriptionID: SubscriptionID?
    private var sceneSubscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy
    private var pendingText = ""
    private var debounceTask: Task<Void, Never>?
    private let contextFilePath: String
    private let maxContextLines = 100

    // MARK: - Init

    init(
        eventHub: EventHubActor,
        config: ConfigActor,
        debounceDuration: Duration = .seconds(2),
        contextFilePath: String? = nil,
        provider: (any LLMProvider)? = nil
    ) {
        self.eventHub = eventHub
        self.config = config
        self.debounceDuration = debounceDuration
        self.overrideProvider = provider
        self.contextFilePath = Self.resolveContextPath(contextFilePath)
    }

    /// Convenience init for tests — wraps a closure as an `LLMProvider`.
    init(
        eventHub: EventHubActor,
        config: ConfigActor,
        debounceDuration: Duration = .seconds(2),
        contextFilePath: String? = nil,
        _ decisionMaker: @escaping @Sendable (String, String) async throws -> BrainDecision
    ) {
        self.eventHub = eventHub
        self.config = config
        self.debounceDuration = debounceDuration
        self.overrideProvider = ClosureProvider(decide: decisionMaker)
        self.contextFilePath = Self.resolveContextPath(contextFilePath)
    }

    private static func resolveContextPath(_ override: String?) -> String {
        if let override { return override }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Banti")
        return appSupport.appendingPathComponent("context.md").path
    }

    // MARK: - BantiModule

    func start() async throws {
        let provider = try await buildProvider()
        ensureContextFileExists()

        transcriptSubscriptionID = await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleTranscript(event, provider: provider)
        }

        sceneSubscriptionID = await eventHub.subscribe(SceneDescriptionEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleSceneDescription(event)
        }

        _health = .healthy
        logger.notice("BrainActor started (context: \(self.contextFilePath, privacy: .public))")
    }

    func stop() async {
        debounceTask?.cancel()
        debounceTask = nil
        if let id = transcriptSubscriptionID {
            await eventHub.unsubscribe(id)
            transcriptSubscriptionID = nil
        }
        if let id = sceneSubscriptionID {
            await eventHub.unsubscribe(id)
            sceneSubscriptionID = nil
        }
    }

    func health() -> ModuleHealth { _health }

    // MARK: - Provider factory

    private func buildProvider() async throws -> any LLMProvider {
        if let override = overrideProvider { return override }

        let selected = (await config.value(for: EnvKey.llmProvider) ?? "claude")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch selected {
        case "cerebras":
            let key = try await config.require(EnvKey.cerebrasAPIKey)
            let model = (await config.value(for: EnvKey.cerebrasModel)) ?? CerebrasProvider.defaultModel
            logger.notice("Brain using Cerebras (\(model, privacy: .public))")
            return CerebrasProvider(apiKey: key, model: model)

        default: // "claude" or unset
            let key = try await config.require(EnvKey.anthropicAPIKey)
            let model = (await config.value(for: EnvKey.anthropicModel)) ?? ClaudeProvider.defaultModel
            logger.notice("Brain using Claude (\(model, privacy: .public))")
            return ClaudeProvider(apiKey: key, model: model)
        }
    }

    // MARK: - Cognitive loop

    private func handleTranscript(_ event: TranscriptSegmentEvent, provider: any LLMProvider) {
        guard event.isFinal else { return }

        // Efference-copy equivalent: ignore Banti's own voice picked up by mic.
        guard event.speakerLabel != Self.selfSpeakerLabel else { return }

        if !pendingText.isEmpty { pendingText += " " }
        pendingText += event.text

        debounceTask?.cancel()
        let debounceDuration = self.debounceDuration
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounceDuration)
            guard !Task.isCancelled else { return }
            await self?.perceiveThinkAct(provider: provider)
        }
    }

    private func perceiveThinkAct(provider: any LLMProvider) async {
        let input = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        guard !input.isEmpty else { return }

        let timestamp = Self.timestamp()
        appendToContext("[\(timestamp)] Pavan: \"\(input)\"")

        let context = readContext()

        do {
            let decision = try await provider.decide(context: context, input: input)

            await eventHub.publish(BrainThoughtEvent(text: decision.content, action: decision.action))

            switch decision.action {
            case "speak":
                appendToContext("[\(Self.timestamp())] (spoke) \"\(decision.content)\"")
                await eventHub.publish(BrainResponseEvent(text: decision.content))
                logger.notice("Brain decided to speak")
            case "think":
                appendToContext("[\(Self.timestamp())] (thought) \(decision.content)")
                logger.notice("Brain thought silently")
            default:
                logger.notice("Brain decided to wait")
            }
        } catch {
            logger.error("Brain error: \(error.localizedDescription, privacy: .public)")
            _health = .degraded(reason: "cognitive loop failed")
        }
    }

    private func handleSceneDescription(_ event: SceneDescriptionEvent) {
        let timestamp = Self.timestamp()
        appendToContext("[\(timestamp)] (scene) \"\(event.text)\"")
        logger.notice("Scene appended to context: \(event.text.prefix(60), privacy: .public)")
    }

    // MARK: - Working memory (context.md)

    private func ensureContextFileExists() {
        let dir = (contextFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: contextFilePath) {
            let header = "# Banti Context\n\n## Conversation\n"
            FileManager.default.createFile(
                atPath: contextFilePath,
                contents: header.data(using: .utf8)
            )
        }
    }

    private func readContext() -> String {
        (try? String(contentsOfFile: contextFilePath, encoding: .utf8)) ?? ""
    }

    private func appendToContext(_ line: String) {
        var content = readContext()
        content += line + "\n"
        let lines = content.components(separatedBy: .newlines)
        if lines.count > maxContextLines {
            let headerEnd = min(3, lines.count)
            let kept = Array(lines[0..<headerEnd]) + Array(lines.suffix(maxContextLines - headerEnd))
            content = kept.joined(separator: "\n")
        }
        try? content.write(toFile: contextFilePath, atomically: true, encoding: .utf8)
    }

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: Date())
    }
}
