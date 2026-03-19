// Sources/BantiCore/MemoryEngine.swift
import Foundation

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
    private let proactiveIntroducer: ProactiveIntroducer
    public let memoryQuery: MemoryQuery

    public init(context: PerceptionContext, audioRouter: AudioRouter, logger: Logger) {
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
        self.proactiveIntroducer = ProactiveIntroducer(logger: logger)
        self.memoryQuery = MemoryQuery(sidecar: sidecar, logger: logger)
    }

    public func start() async {
        await sidecar.start()
        await memoryIngestor.start()
        await selfModel.start()
        await speakerResolver.start()
        startPersonObserver()
        logger.log(source: "memory", message: "MemoryEngine started")
    }

    private func startPersonObserver() {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let person = await self.context.person {
                    await self.proactiveIntroducer.personSeen(person.id, name: person.name)
                }
            }
        }
    }
}
