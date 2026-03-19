// Sources/BantiCore/BrainLoop.swift
import Foundation

// MARK: - SSE types (internal — used by BrainLoop and tests via @testable import)
struct SSEEvent: Decodable {
    let type: String
    let text: String?
}

struct BrainStreamBody: Encodable {
    let track: String
    let snapshot_json: String
    let recent_speech: [String]
    let last_spoke_seconds_ago: Double
    let last_spoke_text: String?
    let is_interruption: Bool
    let current_speech: String?
}

public actor BrainLoop {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let speaker: CartesiaSpeaker
    private let logger: Logger

    private static let heartbeatNanoseconds: UInt64 = 15_000_000_000  // 15s
    private static let pollNanoseconds: UInt64 = 5_000_000_000        // 5s (speech now event-driven)
    private static let cooldownSeconds: Double = 10.0
    private static let maxTranscripts = 5

    private var lastSpoke: Date?
    private var lastSpokeText: String?
    private var recentTranscripts: [String] = []
    private var lastPersonID: String?
    private var lastPersonName: String?
    private var unknownPersonFirstSeen: Date?

    // Active track task handles for cancellation on new trigger
    private var activeReflexTask: Task<Void, Never>?
    private var activeReasoningTask: Task<Void, Never>?

    public init(context: PerceptionContext, sidecar: MemorySidecar,
                speaker: CartesiaSpeaker, logger: Logger) {
        self.context = context
        self.sidecar = sidecar
        self.speaker = speaker
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
        BrainLoop.appendTranscript(&recentTranscripts, new: transcript, isFinal: true)
        await evaluate(reason: "speech: \(transcript)")
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

    private func evaluate(reason: String) async {
        guard BrainLoop.shouldTrigger(lastSpoke: lastSpoke) else { return }
        guard await sidecar.isRunning else { return }

        // Cancel in-flight tasks from prior trigger
        await speaker.cancelTrack(.reflex)
        await speaker.cancelTrack(.reasoning)
        activeReflexTask?.cancel()
        activeReasoningTask?.cancel()

        // Set lastSpoke immediately to prevent duplicate triggers during the ~300ms window
        lastSpoke = Date()

        logger.log(source: "brain", message: "[\(reason)] firing parallel tracks")

        let brain = self
        activeReflexTask = Task { await brain.streamTrack(.reflex) }
        activeReasoningTask = Task { await brain.streamTrack(.reasoning) }
    }

    // MARK: - Stream a single track

    private func streamTrack(_ track: TrackPriority) async {
        guard await sidecar.isRunning else { return }

        let snapshot = await context.snapshotJSON()
        let body = BrainStreamBody(
            track: track.rawValue,
            snapshot_json: snapshot,
            recent_speech: recentTranscripts,
            last_spoke_seconds_ago: BrainLoop.secondsSince(lastSpoke),
            last_spoke_text: lastSpokeText,
            is_interruption: false,       // wired in Task 3
            current_speech: nil           // wired in Task 3
        )

        guard let url = URL(string: "/brain/stream", relativeTo: sidecar.baseURL),
              let bodyData = try? JSONEncoder().encode(body) else { return }

        var request = URLRequest(url: url, timeoutInterval: 25.0)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var spokeSentences: [String] = []

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                guard let data = jsonStr.data(using: .utf8),
                      let event = try? JSONDecoder().decode(SSEEvent.self, from: data) else { continue }
                if event.type == "done" { break }
                if event.type == "sentence", let text = event.text, !text.isEmpty {
                    spokeSentences.append(text)
                    await speaker.streamSpeak(text, track: track)
                }
            }
        } catch {
            logger.log(source: "brain",
                       message: "[warn] \(track.rawValue) track failed: \(error.localizedDescription)")
        }

        // Track 2 overwrites Track 1's lastSpokeText if it spoke
        if !spokeSentences.isEmpty {
            lastSpokeText = spokeSentences.joined(separator: " ")
        }
    }

    // MARK: - Pure static helpers (testable without actor isolation)

    public static func shouldTrigger(lastSpoke: Date?, isInterruption: Bool = false, now: Date = Date()) -> Bool {
        if isInterruption { return true }
        guard let lastSpoke else { return true }
        return now.timeIntervalSince(lastSpoke) > cooldownSeconds
    }

    public static func appendTranscript(_ transcripts: inout [String],
                                        new: String?, isFinal: Bool) {
        guard let new, isFinal, new != transcripts.last else { return }
        if transcripts.count >= maxTranscripts { transcripts.removeFirst() }
        transcripts.append(new)
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
}
