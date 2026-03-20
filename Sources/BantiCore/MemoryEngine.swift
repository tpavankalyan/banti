// Sources/BantiCore/MemoryEngine.swift
import Foundation
import AVFoundation

/// Top-level actor that owns all memory subsystems and cortical graph nodes.
public actor MemoryEngine {
    private let context: PerceptionContext
    private let audioRouter: AudioRouter
    private let logger: Logger

    public let sidecar: MemorySidecar
    public let faceIdentifier: FaceIdentifier
    public let speakerResolver: SpeakerResolver
    private let selfModel: SelfModel
    let cartesiaSpeaker: CartesiaSpeaker   // internal — accessible via @testable import
    public let bantiVoice: BantiVoice
    public let conversationBuffer: ConversationBuffer
    public let memoryQuery: MemoryQuery
    public let eventBus: EventBus
    private var contextAggregator: ContextAggregator?

    // Phase 2 cortical graph nodes
    private var surpriseDetector: SurpriseDetector?
    private var temporalBinder: TemporalBinder?
    private var trackRouter: TrackRouter?
    private var brainstemNode: BrainstemNode?
    private var limbicNode: LimbicNode?
    private var prefrontalNode: PrefrontalNode?
    private var responseArbitrator: ResponseArbitrator?
    private var audioCortex: AudioCortex?
    private var memoryLoader: MemoryLoader?
    private var memoryConsolidator: MemoryConsolidator?

    public init(context: PerceptionContext, audioRouter: AudioRouter, engine: AVAudioEngine, logger: Logger) {
        let sessionID = UUID().uuidString
        let port = Int(ProcessInfo.processInfo.environment["MEMORY_SIDECAR_PORT"] ?? "") ?? 7700

        self.context = context
        self.audioRouter = audioRouter
        self.logger = logger
        self.eventBus = EventBus()

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

        self.selfModel = SelfModel(context: context, sidecar: sidecar, logger: logger)
        self.cartesiaSpeaker = CartesiaSpeaker(engine: engine, logger: logger)

        let selfSpeechLog = SelfSpeechLog()
        let conversationBuffer = ConversationBuffer()
        self.conversationBuffer = conversationBuffer
        self.bantiVoice = BantiVoice(
            cartesiaSpeaker: cartesiaSpeaker,
            selfSpeechLog: selfSpeechLog,
            conversationBuffer: conversationBuffer,
            logger: logger
        )
        self.memoryQuery = MemoryQuery(sidecar: sidecar, logger: logger)
    }

    public func start() async {
        await sidecar.start()
        await selfModel.start()
        await speakerResolver.start()

        let bus = eventBus

        // Wire EventBus to sensor components
        await audioRouter.setBus(bus)
        await bantiVoice.setBus(bus)

        // Start ContextAggregator
        let aggregator = ContextAggregator()
        await aggregator.start(bus: bus)
        contextAggregator = aggregator

        // --- Phase 2: cortical graph nodes ---
        let cerebrasKey = ProcessInfo.processInfo.environment["CEREBRAS_API_KEY"] ?? ""
        let cerebras = makeLiveCerebrasCompletion(apiKey: cerebrasKey)

        // Gate layer
        let surprise = SurpriseDetector(cerebras: cerebras)
        await surprise.start(bus: bus)
        surpriseDetector = surprise

        // Temporal binding
        let binder = TemporalBinder(cerebras: cerebras)
        await binder.start(bus: bus)
        temporalBinder = binder

        // Track router
        let router = TrackRouter(cerebras: cerebras)
        await router.start(bus: bus)
        trackRouter = router

        // Brain tracks
        let brainstem = BrainstemNode(cerebras: cerebras)
        await brainstem.start(bus: bus)
        brainstemNode = brainstem

        let limbic = LimbicNode(cerebras: cerebras)
        await limbic.start(bus: bus)
        limbicNode = limbic

        let prefrontal = PrefrontalNode(cerebras: cerebras)
        await prefrontal.start(bus: bus)
        prefrontalNode = prefrontal

        // Response arbitrator
        let arbitrator = ResponseArbitrator(cerebras: cerebras)
        await arbitrator.start(bus: bus)
        responseArbitrator = arbitrator

        // Audio cortex (efference copy gate for Deepgram/Hume)
        let audio = AudioCortex(deepgram: nil, hume: nil, bus: bus)
        await audio.start(bus: bus)
        audioCortex = audio

        // Memory loader — queries sidecar for person facts
        let capturedSidecar = sidecar
        let querySidecar: SidecarQuery = { personID in
            guard await capturedSidecar.isRunning else {
                return MemoryRetrievedPayload(personID: personID, personName: nil, facts: [])
            }
            struct QueryBody: Encodable { let person_id: String }
            guard let data = await capturedSidecar.post(path: "/memory/query", body: QueryBody(person_id: personID)) else {
                return MemoryRetrievedPayload(personID: personID, personName: nil, facts: [])
            }
            struct QueryResponse: Decodable {
                let person_name: String?
                let facts: [String]
            }
            guard let resp = try? JSONDecoder().decode(QueryResponse.self, from: data) else {
                return MemoryRetrievedPayload(personID: personID, personName: nil, facts: [])
            }
            return MemoryRetrievedPayload(personID: personID, personName: resp.person_name, facts: resp.facts)
        }
        let loader = MemoryLoader(querySidecar: querySidecar)
        await loader.start(bus: bus)
        memoryLoader = loader

        // Memory consolidator — stores episodes to sidecar
        let storeSidecar: SidecarStore = { episodeText in
            struct IngestBody: Encodable {
                let snapshot_json: String
                let wall_ts: String
            }
            let iso = ISO8601DateFormatter().string(from: Date())
            let body = IngestBody(snapshot_json: episodeText, wall_ts: iso)
            _ = await capturedSidecar.post(path: "/memory/ingest", body: body)
        }
        let consolidator = MemoryConsolidator(cerebras: cerebras, storeSidecar: storeSidecar)
        await consolidator.start(bus: bus)
        memoryConsolidator = consolidator

        // Wire BantiVoice to subscribe to motor.speech_plan and speak each sentence
        let voice = bantiVoice
        await bus.subscribe(topic: "motor.speech_plan") { [weak voice] event in
            guard case .speechPlan(let plan) = event.payload else { return }
            for sentence in plan.sentences where !sentence.isEmpty {
                await voice?.say(sentence, track: .reflex)
            }
            await voice?.markPlaybackEnded()
        }

        logger.log(source: "memory", message: "MemoryEngine started — cortical graph active")
    }
}
