import Foundation
import os

// MARK: - Provider protocol

/// Abstracts the LLM call so tests can inject a stub.
protocol AgentLLMProvider: Sendable {
    func respond(systemPrompt: String, userText: String) async throws -> String
}

// MARK: - Real Claude provider

/// Calls the Anthropic Messages API with a text-only system + user message.
struct ClaudeAgentProvider: AgentLLMProvider {
    let apiKey: String
    let model: String

    static let defaultModel = "claude-haiku-4-5-20251001"
    private static let maxTokens = 512

    func respond(systemPrompt: String, userText: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userText]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AgentBridgeError("Invalid response from Claude")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw AgentBridgeError("Claude \(http.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else {
            throw AgentBridgeError("Unexpected Claude response format")
        }
        return text
    }
}

struct AgentBridgeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Bridge actor

/// Subscribes to TurnEndedEvents, calls the LLM with the current context
/// snapshot as the system prompt, and publishes AgentResponseEvent.
actor AgentBridgeActor: BantiModule {
    nonisolated let id = ModuleID("agent-bridge")
    nonisolated let capabilities: Set<Capability> = []

    private static let agentInstructions = """
        You are banti, an ambient AI assistant running on the user's Mac. \
        You observe the user's environment and respond to their voice requests concisely and helpfully. \
        Keep responses brief — they will be displayed in a small notification or spoken aloud.
        """

    private let eventHub: EventHubActor
    private let contextSnapshot: ContextSnapshotActor
    private var llmProvider: (any AgentLLMProvider)?
    private let config: ConfigActor?
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy
    private let logger = Logger(subsystem: "com.banti.agent", category: "Bridge")

    /// Inject a provider directly — used by tests.
    init(eventHub: EventHubActor,
         contextSnapshot: ContextSnapshotActor,
         llmProvider: any AgentLLMProvider) {
        self.eventHub = eventHub
        self.contextSnapshot = contextSnapshot
        self.llmProvider = llmProvider
        self.config = nil
    }

    /// Read API key from config at start() time — used by BantiApp.
    init(eventHub: EventHubActor,
         contextSnapshot: ContextSnapshotActor,
         config: ConfigActor) {
        self.eventHub = eventHub
        self.contextSnapshot = contextSnapshot
        self.llmProvider = nil
        self.config = config
    }

    func start() async throws {
        if llmProvider == nil, let cfg = config {
            let apiKey = try await cfg.require(EnvKey.anthropicAPIKey)
            llmProvider = ClaudeAgentProvider(apiKey: apiKey,
                                              model: ClaudeAgentProvider.defaultModel)
        }
        guard llmProvider != nil else {
            throw AgentBridgeError("No LLM provider configured")
        }
        subscriptionIDs.append(await eventHub.subscribe(TurnEndedEvent.self) { [weak self] event in
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

    // MARK: - Private

    private func handle(_ event: TurnEndedEvent) async {
        guard let provider = llmProvider else { return }
        let snapshot = await contextSnapshot.snapshot()
        let system = Self.agentInstructions + "\n\n" + snapshot.formatted()

        do {
            let response = try await provider.respond(systemPrompt: system, userText: event.text)
            logger.notice("Agent response: \(response.prefix(80), privacy: .public)")
            await eventHub.publish(AgentResponseEvent(userText: event.text, responseText: response))
        } catch {
            logger.error("LLM call failed: \(error.localizedDescription, privacy: .public)")
            _health = .degraded(reason: error.localizedDescription)
        }
    }
}
