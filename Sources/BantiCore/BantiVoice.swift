// Sources/BantiCore/BantiVoice.swift
import Foundation

public actor BantiVoice {
    private let cartesiaSpeaker: CartesiaSpeaker
    private let selfSpeechLog: SelfSpeechLog
    private let conversationBuffer: ConversationBuffer
    private let logger: Logger
    private var bus: EventBus?

    public init(
        cartesiaSpeaker: CartesiaSpeaker,
        selfSpeechLog: SelfSpeechLog,
        conversationBuffer: ConversationBuffer,
        logger: Logger
    ) {
        self.cartesiaSpeaker = cartesiaSpeaker
        self.selfSpeechLog = selfSpeechLog
        self.conversationBuffer = conversationBuffer
        self.logger = logger
    }

    public func setBus(_ bus: EventBus) {
        self.bus = bus
    }

    /// Say a sentence. Called once per SSE sentence inside BrainLoop.streamTrack().
    /// Does NOT call markPlaybackEnded() — that is the caller's responsibility after
    /// the full response is complete (any exit path).
    public func say(_ text: String, track: TrackPriority) async {
        // Publish motor.voice start (efference copy) before TTS audio
        let wordCount = text.split(separator: " ").count
        let estimatedMs = max(500, wordCount * 300)
        if let b = bus {
            let event = BantiEvent(source: "banti_voice", topic: "motor.voice", surprise: 0.0,
                                   payload: .voiceSpeaking(VoiceSpeakingPayload(
                                       speaking: true,
                                       estimatedDurationMs: estimatedMs,
                                       tailWindowMs: 5000,
                                       text: text)))
            await b.publish(event, topic: "motor.voice")
        }
        await selfSpeechLog.register(text: text)        // efference copy — before audio
        await conversationBuffer.addBantiTurn(text)     // conversation record
        await cartesiaSpeaker.streamSpeak(text, track: track)  // actual audio
    }

    /// Called by BrainLoop.streamTrack() unconditionally when the SSE loop exits.
    /// Clears isCurrentlyPlaying and opens the 5s post-playback tail window.
    public func markPlaybackEnded() async {
        // Only publish stop event if we were actually playing (mirrors SelfSpeechLog guard)
        let wasPlaying = await selfSpeechLog.isCurrentlyPlaying
        if wasPlaying, let b = bus {
            let event = BantiEvent(source: "banti_voice", topic: "motor.voice", surprise: 0.0,
                                   payload: .voiceSpeaking(VoiceSpeakingPayload(
                                       speaking: false,
                                       estimatedDurationMs: 0,
                                       tailWindowMs: 5000,
                                       text: nil)))
            await b.publish(event, topic: "motor.voice")
        }
        await selfSpeechLog.markPlaybackEnded()
    }

    /// Async func (not computed var) due to actor isolation on CartesiaSpeaker.
    public func isPlaying() async -> Bool {
        return await cartesiaSpeaker.isPlaying
    }

    public func cancelTrack(_ track: TrackPriority) async {
        await cartesiaSpeaker.cancelTrack(track)
    }

    /// Route attribution through BantiVoice — SelfSpeechLog is fully encapsulated here.
    public func attributeTranscript(
        _ transcript: String,
        arrivedAt: Date = Date()
    ) async -> SpeakerAttributor.Source {
        return await SpeakerAttributor().attribute(transcript, arrivedAt: arrivedAt, selfLog: selfSpeechLog)
    }

    /// Used by PerceptionRouter to filter screen/AX text before context update.
    public func suppressSelfEcho(in text: String) async -> String {
        return await selfSpeechLog.suppressSelfEcho(in: text)
    }

    // MARK: - Test helpers (accessible via @testable import)
    func selfSpeechLogForTest() -> SelfSpeechLog { selfSpeechLog }
    func conversationBufferForTest() -> ConversationBuffer { conversationBuffer }
}
