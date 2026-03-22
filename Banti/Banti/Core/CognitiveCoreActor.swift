// Banti/Banti/Core/CognitiveCoreActor.swift
import Foundation
import os

// MARK: - Protocol types

enum AgentStreamEvent: Sendable {
    case speakChunk(String)
    case speakDone
    case silent
    case error(Error)
}

struct CachedPromptBlock: Sendable {
    let text: String
    let cached: Bool
}

protocol AgentLLMProvider: Sendable {
    func streamResponse(
        systemPrompt: CachedPromptBlock,
        olderContext: CachedPromptBlock,
        recentContext: String,
        triggerSource: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

// MARK: - Real Claude provider

struct ClaudeAgentProvider: AgentLLMProvider {
    let apiKey: String
    let model: String

    static let defaultModel = "claude-haiku-4-5-20251001"

    static var systemPromptText: String {
        """
        You are banti, an ambient AI assistant running on the user's Mac. \
        You observe their environment continuously. Decide whether to speak \
        based on the perception log. Only speak when genuinely useful — \
        silence is always valid. Keep responses brief: 1–2 sentences.
        """
    }

    private static let systemPromptTextInternal = """
        You are banti, an ambient AI assistant running on the user's Mac. \
        You observe their environment continuously through camera, screen, microphone, and \
        accessibility data. You decide whether to speak based on the perception log provided. \
        Only speak when you have something genuinely useful to say — silence is always valid. \
        Keep responses brief: 1–2 sentences. No preamble.
        """

    func streamResponse(
        systemPrompt: CachedPromptBlock,
        olderContext: CachedPromptBlock,
        recentContext: String,
        triggerSource: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = URL(string: "https://api.anthropic.com/v1/messages")!
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    func block(_ b: CachedPromptBlock) -> [String: Any] {
                        var d: [String: Any] = ["type": "text", "text": b.text]
                        if b.cached { d["cache_control"] = ["type": "ephemeral"] }
                        return d
                    }

                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "max_tokens": 256,
                        "system": [block(systemPrompt)],
                        "messages": [[
                            "role": "user",
                            "content": [
                                block(olderContext),
                                ["type": "text", "text": recentContext + "\nTrigger: \(triggerSource)"]
                            ]
                        ]],
                        "tools": [[
                            "name": "speak",
                            "description": "Say something to the user. Only call this if there is something genuinely useful to say. Stay silent by not calling this tool.",
                            "input_schema": [
                                "type": "object",
                                "properties": ["text": ["type": "string", "description": "What to say. 1-2 sentences."]],
                                "required": ["text"]
                            ]
                        ]],
                        "tool_choice": ["type": "auto"]
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish(throwing: CognitiveCoreError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"))
                        return
                    }

                    // SSE parsing state
                    var toolCallSeen = false
                    var extractingText = false
                    var escapeNext = false
                    var partialBuf = ""

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]" else { break }
                        guard let data = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        switch json["type"] as? String ?? "" {
                        case "content_block_start":
                            if let block = json["content_block"] as? [String: Any],
                               block["type"] as? String == "tool_use",
                               block["name"] as? String == "speak" {
                                toolCallSeen = true
                                extractingText = false
                                escapeNext = false
                                partialBuf = ""
                            }
                        case "content_block_delta":
                            guard toolCallSeen,
                                  let delta = json["delta"] as? [String: Any],
                                  delta["type"] as? String == "input_json_delta",
                                  let partial = delta["partial_json"] as? String
                            else { continue }

                            if !extractingText {
                                partialBuf += partial
                                if let range = partialBuf.range(of: #""text":""#) {
                                    extractingText = true
                                    let remainder = String(partialBuf[range.upperBound...])
                                    partialBuf = ""
                                    let extracted = extractUntilQuote(remainder, escapeNext: &escapeNext)
                                    if !extracted.isEmpty { continuation.yield(.speakChunk(extracted)) }
                                }
                            } else {
                                let extracted = extractUntilQuote(partial, escapeNext: &escapeNext)
                                if !extracted.isEmpty { continuation.yield(.speakChunk(extracted)) }
                            }

                        case "content_block_stop":
                            if toolCallSeen { continuation.yield(.speakDone); toolCallSeen = false }

                        case "message_delta":
                            if let delta = json["delta"] as? [String: Any],
                               delta["stop_reason"] as? String == "end_turn",
                               !toolCallSeen {
                                continuation.yield(.silent)
                            }
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() }
                    else { continuation.finish(throwing: error) }
                }
            }
        }
    }

    /// Extracts characters from `s` until an unescaped closing `"`, updating escape state.
    private func extractUntilQuote(_ s: String, escapeNext: inout Bool) -> String {
        var result = ""
        for c in s {
            if escapeNext {
                switch c {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(c)
                }
                escapeNext = false
            } else if c == "\\" {
                escapeNext = true
            } else if c == "\"" {
                break
            } else {
                result.append(c)
            }
        }
        return result
    }
}

struct CognitiveCoreError: Error, LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

// MARK: - Actor

actor CognitiveCoreActor: BantiModule {
    nonisolated let id = ModuleID("cognitive-core")
    nonisolated let capabilities: Set<Capability> = []

    private let eventHub: EventHubActor
    private let perceptionLog: PerceptionLogActor
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy
    private let logger = Logger(subsystem: "com.banti.cognitive", category: "Core")

    // Provider — optional to support config-based lazy init
    private var provider: (any AgentLLMProvider)?
    private let config: ConfigActor?

    // Epoch — single source of truth
    private var epoch: Int = 0
    private var streamTask: Task<Void, Never>?
    private var sentenceBuffer: String = ""
    private var pendingTurnText: String = ""

    // Trigger debounce
    private var lastScreenTrigger: Date = .distantPast
    private var lastSceneTrigger: Date = .distantPast
    private var lastAppTrigger: Date = .distantPast

    private let screenInterval: TimeInterval
    private let sceneInterval: TimeInterval
    private let appInterval: TimeInterval
    private let screenThreshold: Float
    private let sceneThreshold: Float

    /// Inject provider directly — used by tests.
    init(eventHub: EventHubActor,
         perceptionLog: PerceptionLogActor,
         provider: any AgentLLMProvider,
         screenInterval: TimeInterval = 5,
         sceneInterval: TimeInterval = 10,
         appInterval: TimeInterval = 5,
         screenThreshold: Float = 0.3,
         sceneThreshold: Float = 0.3) {
        self.eventHub = eventHub
        self.perceptionLog = perceptionLog
        self.provider = provider
        self.config = nil
        self.screenInterval = screenInterval
        self.sceneInterval = sceneInterval
        self.appInterval = appInterval
        self.screenThreshold = screenThreshold
        self.sceneThreshold = sceneThreshold
    }

    /// Read API key from config at start() — used by BantiApp.
    init(eventHub: EventHubActor,
         perceptionLog: PerceptionLogActor,
         config: ConfigActor,
         screenInterval: TimeInterval = 5,
         sceneInterval: TimeInterval = 10,
         appInterval: TimeInterval = 5,
         screenThreshold: Float = 0.3,
         sceneThreshold: Float = 0.3) {
        self.eventHub = eventHub
        self.perceptionLog = perceptionLog
        self.provider = nil
        self.config = config
        self.screenInterval = screenInterval
        self.sceneInterval = sceneInterval
        self.appInterval = appInterval
        self.screenThreshold = screenThreshold
        self.sceneThreshold = sceneThreshold
    }

    func start() async throws {
        // Resolve provider from config if not injected
        if provider == nil, let cfg = config {
            let apiKey = try await cfg.require(EnvKey.anthropicAPIKey)
            let model = await cfg.value(for: EnvKey.claudeModel) ?? ClaudeAgentProvider.defaultModel
            provider = ClaudeAgentProvider(apiKey: apiKey, model: model)
        }
        guard provider != nil else { throw CognitiveCoreError("No LLM provider configured") }

        subscriptionIDs.append(await eventHub.subscribe(TurnEndedEvent.self)         { [weak self] e in await self?.handleTurnEnded(e) })
        subscriptionIDs.append(await eventHub.subscribe(TurnStartedEvent.self)       { [weak self] e in await self?.handleTurnStarted(e) })
        subscriptionIDs.append(await eventHub.subscribe(ScreenDescriptionEvent.self) { [weak self] e in await self?.handleScreenDesc(e) })
        subscriptionIDs.append(await eventHub.subscribe(SceneDescriptionEvent.self)  { [weak self] e in await self?.handleSceneDesc(e) })
        subscriptionIDs.append(await eventHub.subscribe(ActiveAppEvent.self)         { [weak self] e in await self?.handleAppSwitch(e) })
        _health = .healthy
    }

    func stop() async {
        streamTask?.cancel()
        streamTask = nil
        for s in subscriptionIDs { await eventHub.unsubscribe(s) }
        subscriptionIDs.removeAll()
    }

    func health() async -> ModuleHealth { _health }

    // MARK: - Trigger handlers

    private func handleTurnEnded(_ event: TurnEndedEvent) {
        pendingTurnText = event.text
        launchStream(triggerSource: "user_speech")
    }

    private func handleTurnStarted(_ event: TurnStartedEvent) {
        streamTask?.cancel()
        streamTask = nil
        sentenceBuffer = ""
        epoch += 1
        let e = epoch
        Task { await eventHub.publish(InterruptEvent(epoch: e)) }
    }

    private func handleScreenDesc(_ event: ScreenDescriptionEvent) {
        guard let dist = event.changeDistance, dist >= screenThreshold else { return }
        let now = Date()
        guard now.timeIntervalSince(lastScreenTrigger) >= screenInterval else { return }
        lastScreenTrigger = now
        launchStream(triggerSource: "screen_change")
    }

    private func handleSceneDesc(_ event: SceneDescriptionEvent) {
        guard event.changeDistance >= sceneThreshold else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSceneTrigger) >= sceneInterval else { return }
        lastSceneTrigger = now
        launchStream(triggerSource: "scene_change")
    }

    private func handleAppSwitch(_ event: ActiveAppEvent) {
        let now = Date()
        guard now.timeIntervalSince(lastAppTrigger) >= appInterval else { return }
        lastAppTrigger = now
        launchStream(triggerSource: "app_switch")
    }

    // MARK: - Streaming

    private func launchStream(triggerSource: String) {
        guard let prov = provider else {
            _health = .degraded(reason: "No LLM provider configured")
            return
        }
        streamTask?.cancel()
        sentenceBuffer = ""  // clear any partial sentence from the preempted stream
        let currentEpoch = epoch
        let capturedTurnText = pendingTurnText
        let log = perceptionLog.log()
        let stream = prov.streamResponse(
            systemPrompt: CachedPromptBlock(text: ClaudeAgentProvider.systemPromptText, cached: true),
            olderContext: CachedPromptBlock(text: log.formattedOlder(), cached: true),
            recentContext: log.formattedRecent(),
            triggerSource: triggerSource
        )
        streamTask = Task {
            await runStream(stream: stream, triggerSource: triggerSource,
                            epoch: currentEpoch, turnText: capturedTurnText)
        }
    }

    private func runStream(
        stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        triggerSource: String,
        epoch: Int,
        turnText: String
    ) async {
        var accumulated = ""
        do {
            for try await event in stream {
                guard !Task.isCancelled else { return }
                switch event {
                case .speakChunk(let text):
                    sentenceBuffer += text
                    accumulated += text
                    if sentenceBuffer.count >= 15,
                       let last = sentenceBuffer.last,
                       ".!?".contains(last) {
                        let chunk = sentenceBuffer.trimmingCharacters(in: .whitespaces)
                        sentenceBuffer = ""
                        await eventHub.publish(SpeakChunkEvent(text: chunk, epoch: epoch))
                    }
                case .speakDone:
                    if !sentenceBuffer.isEmpty {
                        let chunk = sentenceBuffer.trimmingCharacters(in: .whitespaces)
                        sentenceBuffer = ""
                        await eventHub.publish(SpeakChunkEvent(text: chunk, epoch: epoch))
                    }
                    let userText = triggerSource == "user_speech" ? turnText : ""
                    await eventHub.publish(AgentResponseEvent(
                        userText: userText,
                        responseText: accumulated,
                        sourceModule: id))
                case .silent:
                    return
                case .error(let err):
                    logger.error("LLM stream error: \(err.localizedDescription, privacy: .public)")
                    _health = .degraded(reason: err.localizedDescription)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Stream threw: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - PerceptionLog formatting helpers

extension PerceptionLog {
    func formattedOlder() -> String {
        let now = Date()
        let cutoff = now.addingTimeInterval(-recentWindowSeconds)
        let older = entries.filter { $0.timestamp < cutoff }
        guard !older.isEmpty else { return "(no older context)" }
        return "=== Perception Log — Older (>\(Int(recentWindowSeconds))s) ===\n" +
            older.map { formatLogEntry($0, now: now) }.joined(separator: "\n")
    }

    func formattedRecent() -> String {
        let now = Date()
        let cutoff = now.addingTimeInterval(-recentWindowSeconds)
        let recent = entries.filter { $0.timestamp >= cutoff }
        var lines: [String] = []
        if !recent.isEmpty {
            lines.append("=== Perception Log — Recent (<\(Int(recentWindowSeconds))s) ===")
            lines.append(contentsOf: recent.map { formatLogEntry($0, now: now) })
        }
        lines.append("=== Active Now ===")
        if let app = activeApp { lines.append("App: \(app.appName) (\(app.bundleIdentifier))") }
        if let ax = axFocus {
            var l = "Focus: \(ax.elementRole)"
            if let t = ax.elementTitle { l += " — \(t)" }
            lines.append(l)
        }
        return lines.joined(separator: "\n")
    }

    // Named differently from the private `formatEntry` already on PerceptionLog.formatted()
    fileprivate func formatLogEntry(_ e: PerceptionLogEntry, now: Date) -> String {
        let age = max(0, Int(now.timeIntervalSince(e.timestamp)))
        let k: String
        switch e.kind {
        case .screenDescription: k = "SCREEN    "
        case .sceneDescription:  k = "SCENE     "
        case .transcript:        k = "TRANSCRIPT"
        case .appSwitch:         k = "APP       "
        case .axFocus:           k = "AX_FOCUS  "
        }
        var line = "[\(String(format: "%3d", age))s ago] \(k)"
        if let d = e.changeDistance { line += " dist=\(String(format: "%.2f", d))" }
        return line + " | \(e.summary)"
    }
}
