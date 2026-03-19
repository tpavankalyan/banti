// Sources/BantiCore/MemoryEngine.swift
import Foundation
import AVFoundation

/// Top-level actor that owns all memory subsystems.
public actor MemoryEngine {
    private let context: PerceptionContext
    private let audioRouter: AudioRouter
    private let logger: Logger

    public let sidecar: MemorySidecar
    public let faceIdentifier: FaceIdentifier
    public let speakerResolver: SpeakerResolver
    private let memoryIngestor: MemoryIngestor
    private let selfModel: SelfModel
    public let brainLoop: BrainLoop
    let cartesiaSpeaker: CartesiaSpeaker   // internal — accessible via @testable import
    public let memoryQuery: MemoryQuery

    public init(context: PerceptionContext, audioRouter: AudioRouter, engine: AVAudioEngine, logger: Logger) {
        let sessionID = UUID().uuidString
        let port = Int(ProcessInfo.processInfo.environment["MEMORY_SIDECAR_PORT"] ?? "") ?? 7700

        self.context = context
        self.audioRouter = audioRouter
        self.logger = logger

        self.sidecar = MemorySidecar(logger: logger, port: port)

        self.faceIdentifier = FaceIdentifier(
            context: context,
            sidecar: sidecar,
            logger: logger,
            sessionID: sessionID
        )

        self.speakerResolver = SpeakerResolver(
            context: context,
            audioRouter: audioRouter,
            sidecar: sidecar,
            logger: logger,
            sessionID: sessionID
        )

        self.memoryIngestor = MemoryIngestor(context: context, sidecar: sidecar, logger: logger)
        self.selfModel = SelfModel(context: context, sidecar: sidecar, logger: logger)
        self.cartesiaSpeaker = CartesiaSpeaker(engine: engine, logger: logger)
        self.brainLoop = BrainLoop(context: context, sidecar: sidecar,
                                   speaker: cartesiaSpeaker, logger: logger)
        self.memoryQuery = MemoryQuery(sidecar: sidecar, logger: logger)
    }

    public func start() async {
        await sidecar.start()
        await memoryIngestor.start()
        await selfModel.start()
        await speakerResolver.start()
        await brainLoop.start()    // non-async on BrainLoop — internally spawns Tasks
        // Wire Deepgram final-transcript callback directly into BrainLoop
        let loop = brainLoop
        await audioRouter.setTranscriptCallback { @Sendable transcript in
            await loop.onFinalTranscript(transcript)
        }
        logger.log(source: "memory", message: "transcript callback wired")
        logger.log(source: "memory", message: "MemoryEngine started")
    }
}
