// Sources/BantiCore/SpeakerResolver.swift
import Foundation

public actor SpeakerResolver {
    private let context: PerceptionContext
    private let audioRouter: AudioRouter
    private let sidecar: MemorySidecar
    private let logger: Logger
    private let sessionID: String

    public static let minAccumulationBytes = 96_000  // 3s at 16kHz mono Int16

    private var sessionMap: [Int: String] = [:]
    private var pendingSet: Set<Int> = []

    public init(context: PerceptionContext, audioRouter: AudioRouter, sidecar: MemorySidecar,
                logger: Logger, sessionID: String) {
        self.context = context
        self.audioRouter = audioRouter
        self.sidecar = sidecar
        self.logger = logger
        self.sessionID = sessionID
    }

    public func start() {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.poll()
            }
        }
    }

    public func cacheResolvedName(_ name: String, forSpeakerID id: Int) {
        sessionMap[id] = name
    }

    public func resolvedName(forSpeakerID id: Int) -> String? {
        sessionMap[id]
    }

    public var pendingSpeakerIDs: Set<Int> { pendingSet }

    private func poll() async {
        guard await sidecar.isRunning else { return }
        guard let speech = await context.speech,
              let speakerID = speech.speakerID else { return }

        if let name = sessionMap[speakerID] {
            if speech.resolvedName == nil {
                let updated = SpeechState(
                    transcript: speech.transcript,
                    speakerID: speech.speakerID,
                    isFinal: speech.isFinal,
                    confidence: speech.confidence,
                    resolvedName: name,
                    updatedAt: speech.updatedAt
                )
                await context.update(.speech(updated))
            }
            return
        }

        guard !pendingSet.contains(speakerID) else { return }

        let pcmData = await audioRouter.readPCMRingBuffer()
        guard pcmData.count >= SpeakerResolver.minAccumulationBytes else { return }

        pendingSet.insert(speakerID)
        let capturedPCM = pcmData
        let capturedSpeakerID = speakerID

        Task { [weak self] in
            guard let self else { return }
            await self.resolve(speakerID: capturedSpeakerID, pcmData: capturedPCM)
        }
    }

    private func resolve(speakerID: Int, pcmData: Data) async {
        defer { pendingSet.remove(speakerID) }

        struct VoiceRequest: Encodable {
            let pcm_b64: String
            let deepgram_speaker_id: Int
            let session_id: String
        }

        let body = VoiceRequest(
            pcm_b64: pcmData.base64EncodedString(),
            deepgram_speaker_id: speakerID,
            session_id: sessionID
        )

        guard let responseData = await sidecar.post(path: "/identity/voice", body: body) else { return }

        struct VoiceResponse: Decodable {
            let matched: Bool
            let person_id: String
            let name: String?
            let confidence: Float
        }

        guard let response = try? JSONDecoder().decode(VoiceResponse.self, from: responseData) else { return }

        let resolvedName = response.name ?? response.person_id
        sessionMap[speakerID] = resolvedName

        if let speech = await context.speech, speech.speakerID == speakerID {
            let updated = SpeechState(
                transcript: speech.transcript,
                speakerID: speech.speakerID,
                isFinal: speech.isFinal,
                confidence: speech.confidence,
                resolvedName: resolvedName,
                updatedAt: speech.updatedAt
            )
            await context.update(.speech(updated))
        }

        logger.log(source: "memory", message: "speaker \(speakerID) resolved: \(resolvedName)")
    }
}
