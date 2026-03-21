import Foundation
import os

struct BrainDecision: Sendable {
    let action: String
    let content: String
}

actor BrainActor: BantiModule {
    nonisolated let id = ModuleID("brain")
    nonisolated let capabilities: Set<Capability> = [.reasoning]

    static let systemPromptTemplate = """
    You are Banti, Pavan's personal assistant. You can hear what he says.

    Your current working memory:
    <CONTEXT>

    New input just arrived:
    <INPUT>

    Decide what to do. Respond with ONLY valid JSON, no other text:
    {"action": "think", "content": "..."} or {"action": "speak", "content": "..."} or {"action": "wait", "content": ""}

    - "think": internal thought. Content is written to your memory but NOT spoken aloud.
    - "speak": say this to Pavan. Content will be spoken aloud via TTS. Keep it concise and conversational.
    - "wait": nothing to do right now. Content can be empty.

    Guidelines:
    - Only speak when Pavan is addressing you or asking a question
    - If Pavan asks you a direct question or contact check like "can you hear me", "are you there", or a short greeting meant for you, answer aloud even if he has asked something similar recently
    - Do not stay silent just because the question seems repetitive if it is clearly directed at you
    - Use think to reason, plan, or note observations silently
    - Use wait when Pavan is talking to someone else or the input is ambient noise
    """

    private let logger = Logger(subsystem: "com.banti.brain", category: "Brain")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let debounceDuration: Duration
    private let decisionMaker: (@Sendable (String, String) async throws -> BrainDecision)?

    private var transcriptSubscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy
    private var pendingText = ""
    private var debounceTask: Task<Void, Never>?
    private let contextFilePath: String
    private let maxContextLines = 100

    init(
        eventHub: EventHubActor,
        config: ConfigActor,
        debounceDuration: Duration = .seconds(2),
        contextFilePath: String? = nil,
        decisionMaker: (@Sendable (String, String) async throws -> BrainDecision)? = nil
    ) {
        self.eventHub = eventHub
        self.config = config
        self.debounceDuration = debounceDuration
        self.decisionMaker = decisionMaker

        if let contextFilePath {
            self.contextFilePath = contextFilePath
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("Banti")
            self.contextFilePath = appSupport.appendingPathComponent("context.md").path
        }
    }

    func start() async throws {
        let cerebrasKey = await config.value(for: EnvKey.cerebrasAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cerebrasKey.isEmpty else {
            logger.warning("CEREBRAS_API_KEY not set — BrainActor idle; mic/ASR pipeline still runs")
            _health = .degraded(reason: "CEREBRAS_API_KEY not set")
            return
        }

        ensureContextFileExists()

        transcriptSubscriptionID = await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleTranscript(event)
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
    }

    func health() -> ModuleHealth { _health }

    static func makeSystemPrompt(context: String, input: String) -> String {
        systemPromptTemplate
            .replacingOccurrences(of: "<CONTEXT>", with: context)
            .replacingOccurrences(of: "<INPUT>", with: input)
    }

    // MARK: - Cognitive loop

    private func handleTranscript(_ event: TranscriptSegmentEvent) {
        guard event.isFinal else { return }

        if !pendingText.isEmpty { pendingText += " " }
        pendingText += event.text

        debounceTask?.cancel()
        let debounceDuration = self.debounceDuration
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounceDuration)
            guard !Task.isCancelled else { return }
            await self?.perceiveThinkAct()
        }
    }

    private func perceiveThinkAct() async {
        let input = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        guard !input.isEmpty else { return }

        let timestamp = Self.timestamp()
        appendToContext("[\(timestamp)] Pavan: \"\(input)\"")

        let context = readContext()

        do {
            let decision: BrainDecision
            if let decisionMaker {
                decision = try await decisionMaker(context, input)
            } else {
                decision = try await callCerebras(context: context, input: input)
            }

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

    // MARK: - Cerebras API

    private func callCerebras(context: String, input: String) async throws -> BrainDecision {
        let apiKey = try await config.require(EnvKey.cerebrasAPIKey)
        let model = (await config.value(for: EnvKey.cerebrasModel)) ?? "llama3.1-8b"

        let prompt = Self.makeSystemPrompt(context: context, input: input)

        let url = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
            ],
            "max_tokens": 256,
            "temperature": 0.3,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ConfigError(message: "Invalid response from Cerebras")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw ConfigError(message: "Cerebras \(http.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw ConfigError(message: "Unexpected Cerebras response format")
        }

        return parseDecision(content)
    }

    private func parseDecision(_ raw: String) -> BrainDecision {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        if let jsonData = cleaned.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let action = parsed["action"] as? String,
           let content = parsed["content"] as? String {
            let validActions = ["think", "speak", "wait"]
            if validActions.contains(action) {
                return BrainDecision(action: action, content: content)
            }
        }

        logger.warning("Failed to parse structured decision, falling back to wait: \(raw.prefix(200), privacy: .public)")
        return BrainDecision(action: "wait", content: "")
    }
}
