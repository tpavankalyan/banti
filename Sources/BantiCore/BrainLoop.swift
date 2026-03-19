// Sources/BantiCore/BrainLoop.swift
import Foundation

public actor BrainLoop {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let speaker: CartesiaSpeaker
    private let logger: Logger

    private static let heartbeatNanoseconds: UInt64 = 15_000_000_000  // 15s
    private static let pollNanoseconds: UInt64 = 2_000_000_000        // 2s
    private static let cooldownSeconds: Double = 10.0
    private static let maxTranscripts = 5

    private var lastSpoke: Date?
    private var lastSpokeText: String?
    private var recentTranscripts: [String] = []
    private var lastPersonID: String?
    private var lastPersonName: String?
    private var unknownPersonFirstSeen: Date?

    public init(context: PerceptionContext, sidecar: MemorySidecar,
                speaker: CartesiaSpeaker, logger: Logger) {
        self.context = context
        self.sidecar = sidecar
        self.speaker = speaker
        self.logger = logger
    }

    // start() is non-async — spawns internal Tasks
    public func start() {
        // Heartbeat loop
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BrainLoop.heartbeatNanoseconds)
                await self.evaluate(reason: "heartbeat")
            }
        }
        // Event polling loop (2s)
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BrainLoop.pollNanoseconds)
                await self.pollEvents()
            }
        }
    }

    private func pollEvents() async {
        // 1. Accumulate final transcripts
        let currentSpeech = await context.speech
        BrainLoop.appendTranscript(&recentTranscripts,
                                   new: currentSpeech?.transcript,
                                   isFinal: currentSpeech?.isFinal ?? false)

        let person = await context.person

        // 2. Trigger on new person (ID changed)
        if let person {
            if person.id != lastPersonID {
                lastPersonID = person.id
                unknownPersonFirstSeen = person.name == nil ? Date() : nil
                await evaluate(reason: "new person detected")
            }

            // 3. Trigger when name just resolved (unknown → named)
            if BrainLoop.nameJustResolved(previous: lastPersonName, current: person.name) {
                lastPersonName = person.name
                await evaluate(reason: "person name resolved: \(person.name ?? "")")
            } else {
                lastPersonName = person.name
            }

            // 4. Trigger when unknown person present > 30s
            if person.name == nil,
               let firstSeen = unknownPersonFirstSeen,
               BrainLoop.unknownPersonExceedsThreshold(firstSeen: firstSeen) {
                unknownPersonFirstSeen = nil  // reset so we don't re-trigger immediately
                await evaluate(reason: "unknown person present > 30s")
            }
        } else {
            lastPersonID = nil
            lastPersonName = nil
            unknownPersonFirstSeen = nil
        }

        // 5. Trigger on voice emotion spike (Hume VoiceEmotionState)
        if let ve = await context.voiceEmotion {
            let topScore = ve.emotions.map { $0.score }.max() ?? 0
            if BrainLoop.isEmotionSpike(topScore: topScore) {
                await evaluate(reason: "emotion spike detected")
            }
        }
    }

    private func evaluate(reason: String) async {
        guard BrainLoop.shouldTrigger(lastSpoke: lastSpoke) else { return }
        guard await sidecar.isRunning else { return }

        let snapshot = await context.snapshotJSON()
        let secondsAgo = BrainLoop.secondsSince(lastSpoke)

        struct BrainBody: Encodable {
            let snapshot_json: String
            let recent_speech: [String]
            let last_spoke_seconds_ago: Double
            let last_spoke_text: String?
        }
        let body = BrainBody(
            snapshot_json: snapshot,
            recent_speech: recentTranscripts,
            last_spoke_seconds_ago: secondsAgo,
            last_spoke_text: lastSpokeText
        )

        guard let url = URL(string: "/brain/decide", relativeTo: sidecar.baseURL),
              let bodyData = try? JSONEncoder().encode(body) else { return }

        var request = URLRequest(url: url, timeoutInterval: 10.0)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decision = try JSONDecoder().decode(ProactiveDecision.self, from: data)
            logger.log(source: "brain", message: "[\(reason)] \(decision.action): \(decision.reason)")
            if decision.action == "speak", let text = decision.text, !text.isEmpty {
                lastSpoke = Date()
                lastSpokeText = text
                await speaker.speak(text)
            }
        } catch {
            logger.log(source: "brain", message: "[warn] brain/decide failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pure static helpers (testable without actor isolation)

    public static func shouldTrigger(lastSpoke: Date?, now: Date = Date()) -> Bool {
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
