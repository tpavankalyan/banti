// Sources/BantiCore/BrainLoop.swift
import Foundation

// MARK: - SSE types (internal — used by BrainLoop and tests via @testable import)
struct SSEEvent: Decodable {
    let type: String
    let text: String?
}

// New types replacing the old BrainStreamBody
struct ConversationTurnDTO: Encodable {
    let speaker: String      // "banti" or "human"
    let text: String
    let timestamp: Double    // unix timestamp
}

struct BrainStreamBody: Encodable {
    let track: String
    let ambient_context: String          // was: snapshot_json
    let conversation_history: [ConversationTurnDTO]  // was: recent_speech: [String]
    let last_banti_utterance: String?    // was: last_spoke_text
    let last_spoke_seconds_ago: Double
    let is_interruption: Bool
    let current_speech: String?
}

public actor BrainLoop {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let bantiVoice: BantiVoice
    private let conversationBuffer: ConversationBuffer
    private let logger: Logger

    private static let heartbeatNanoseconds: UInt64 = 15_000_000_000  // 15s
    private static let pollNanoseconds: UInt64 = 5_000_000_000        // 5s (speech now event-driven)
    private static let cooldownSeconds: Double = 10.0

    private var currentlySpeaking: String?
    private var lastSpoke: Date?
    private var lastPersonID: String?
    private var lastPersonName: String?
    private var unknownPersonFirstSeen: Date?

    // Active track task handles for cancellation on new trigger
    private var activeReflexTask: Task<Void, Never>?
    private var activeReasoningTask: Task<Void, Never>?

    public init(context: PerceptionContext, sidecar: MemorySidecar,
                bantiVoice: BantiVoice,
                conversationBuffer: ConversationBuffer,
                logger: Logger) {
        self.context = context
        self.sidecar = sidecar
        self.bantiVoice = bantiVoice
        self.conversationBuffer = conversationBuffer
        self.logger = logger
    }

    // MARK: - Startup

    public func start() {
        // Heartbeat loop
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BrainLoop.heartbeatNanoseconds)
                await self.evaluate(reason: "heartbeat")
            }
        }
        // Event polling loop — face/emotion/person events only (not speech)
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BrainLoop.pollNanoseconds)
                await self.pollEvents()
            }
        }
    }

    // MARK: - Direct speech callback (event-driven, replaces transcript accumulation in pollEvents)

    public func onFinalTranscript(_ transcript: String) async {
        // Capture isPlaying before attribution — used for interruption detection only
        let wasPlaying = await bantiVoice.isPlaying()
        let source = await bantiVoice.attributeTranscript(transcript, arrivedAt: Date())
        guard source == .human else { return }
        await conversationBuffer.addHumanTurn(transcript)
        let isInterruption = wasPlaying && BrainLoop.isInterruptionCandidate(transcript)
        await evaluate(reason: "speech: \(transcript)", isInterruption: isInterruption)
    }

    // MARK: - Event polling (face / emotion / person — no speech)

    private func pollEvents() async {
        let person = await context.person

        if let person {
            if person.id != lastPersonID {
                lastPersonID = person.id
                unknownPersonFirstSeen = person.name == nil ? Date() : nil
                await evaluate(reason: "new person detected")
            }
            if BrainLoop.nameJustResolved(previous: lastPersonName, current: person.name) {
                lastPersonName = person.name
                await evaluate(reason: "person name resolved: \(person.name ?? "")")
            } else {
                lastPersonName = person.name
            }
            if person.name == nil,
               let firstSeen = unknownPersonFirstSeen,
               BrainLoop.unknownPersonExceedsThreshold(firstSeen: firstSeen) {
                unknownPersonFirstSeen = nil
                await evaluate(reason: "unknown person present > 30s")
            }
        } else {
            lastPersonID = nil
            lastPersonName = nil
            unknownPersonFirstSeen = nil
        }

        if let ve = await context.voiceEmotion {
            let topScore = ve.emotions.map { $0.score }.max() ?? 0
            if BrainLoop.isEmotionSpike(topScore: topScore) {
                await evaluate(reason: "emotion spike detected")
            }
        }
    }

    // MARK: - Evaluate / fire parallel tracks

    private func evaluate(reason: String, isInterruption: Bool = false, currentSpeech: String? = nil) async {
        guard BrainLoop.shouldTrigger(lastSpoke: lastSpoke, isInterruption: isInterruption) else { return }
        guard await sidecar.isRunning else { return }

        // Reset mid-speech tracking before cancelling in-flight tasks
        currentlySpeaking = nil

        // Cancel in-flight tasks from prior trigger
        await bantiVoice.cancelTrack(.reflex)
        await bantiVoice.cancelTrack(.reasoning)
        activeReflexTask?.cancel()
        activeReasoningTask?.cancel()

        // Set lastSpoke immediately to prevent duplicate triggers during the ~300ms window
        lastSpoke = Date()

        logger.log(source: "brain", message: "[\(reason)] firing parallel tracks")

        let brain = self
        activeReflexTask = Task { await brain.streamTrack(.reflex, isInterruption: isInterruption, currentSpeech: currentSpeech) }
        activeReasoningTask = Task { await brain.streamTrack(.reasoning, isInterruption: isInterruption, currentSpeech: currentSpeech) }
    }

    // MARK: - Stream a single track

    private func streamTrack(_ track: TrackPriority, isInterruption: Bool = false, currentSpeech: String? = nil) async {
        guard await sidecar.isRunning else {
            await bantiVoice.markPlaybackEnded()
            return
        }

        let snapshot = await context.snapshotJSON()
        let turns = await conversationBuffer.recentTurns(limit: 10)
        let dtoTurns = turns.map {
            ConversationTurnDTO(speaker: $0.speaker.rawValue, text: $0.text,
                                timestamp: $0.timestamp.timeIntervalSince1970)
        }
        let body = BrainStreamBody(
            track: track.rawValue,
            ambient_context: snapshot,
            conversation_history: dtoTurns,
            last_banti_utterance: await conversationBuffer.lastBantiUtterance(),
            last_spoke_seconds_ago: BrainLoop.secondsSince(lastSpoke),
            is_interruption: isInterruption,
            current_speech: currentSpeech
        )

        guard let url = URL(string: "/brain/stream", relativeTo: sidecar.baseURL),
              let bodyData = try? JSONEncoder().encode(body) else {
            await bantiVoice.markPlaybackEnded()
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 25.0)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                if Task.isCancelled { break }     // break (not return) so markPlaybackEnded runs
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                guard let data = jsonStr.data(using: .utf8),
                      let event = try? JSONDecoder().decode(SSEEvent.self, from: data) else { continue }
                if event.type == "done" { break }
                if event.type == "sentence", let text = event.text, !text.isEmpty {
                    currentlySpeaking = text
                    await bantiVoice.say(text, track: track)
                }
            }
        } catch {
            logger.log(source: "brain",
                       message: "[warn] \(track.rawValue) track failed: \(error.localizedDescription)")
        }

        // Unconditional: close playback window whether we spoke, were cancelled, or errored.
        await bantiVoice.markPlaybackEnded()
    }

    // MARK: - Pure static helpers (testable without actor isolation)

    public static func shouldTrigger(lastSpoke: Date?, isInterruption: Bool = false, now: Date = Date()) -> Bool {
        if isInterruption { return true }
        guard let lastSpoke else { return true }
        return now.timeIntervalSince(lastSpoke) > cooldownSeconds
    }

    public static func secondsSince(_ date: Date?, now: Date = Date()) -> Double {
        guard let date else { return 9999.0 }
        return now.timeIntervalSince(date)
    }

    /// Returns true when Hume voice emotion top score exceeds 0.7 (strong signal).
    public static func isEmotionSpike(topScore: Float) -> Bool {
        return topScore >= 0.7
    }

    /// Returns true when an unnamed person has been visible for > 30 seconds.
    public static func unknownPersonExceedsThreshold(firstSeen: Date, now: Date = Date()) -> Bool {
        return now.timeIntervalSince(firstSeen) > 30.0
    }

    /// Returns true when name transitions from nil to a non-nil value (just resolved).
    public static func nameJustResolved(previous: String?, current: String?) -> Bool {
        return previous == nil && current != nil
    }

    /// Returns true when the transcript has 2+ words — minimum threshold to treat as an
    /// intentional interruption (single-word fragments may be AEC convergence noise).
    public static func isInterruptionCandidate(_ transcript: String) -> Bool {
        transcript.split(separator: " ").count >= 2
    }
}
