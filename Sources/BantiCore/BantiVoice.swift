// Sources/BantiCore/BantiVoice.swift
import Foundation

public actor BantiVoice {
    private let cartesiaSpeaker: CartesiaSpeaker
    private let selfSpeechLog: SelfSpeechLog
    private let conversationBuffer: ConversationBuffer
    private let logger: Logger

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

    /// Say a sentence. Called once per SSE sentence inside BrainLoop.streamTrack().
    /// Does NOT call markPlaybackEnded() — that is the caller's responsibility after
    /// the full response is complete (any exit path).
    public func say(_ text: String, track: TrackPriority) async {
        await selfSpeechLog.register(text: text)        // efference copy — before audio
        await conversationBuffer.addBantiTurn(text)     // conversation record
        await cartesiaSpeaker.streamSpeak(text, track: track)  // actual audio
    }

    /// Called by BrainLoop.streamTrack() unconditionally when the SSE loop exits.
    /// Clears isCurrentlyPlaying and opens the 5s post-playback tail window.
    public func markPlaybackEnded() async {
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
