import SwiftUI
import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }
}

@main
struct BantiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel: EventLogViewModel
    private let logger = Logger(subsystem: "com.banti.app", category: "Lifecycle")

    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let stateRegistry: StateRegistryActor
    private let supervisor: ModuleSupervisorActor
    private let eventLogger: EventLoggerActor
    private let micCapture: MicrophoneCaptureActor
    private let deepgram: DeepgramStreamingActor
    private let projection: TranscriptProjectionActor
    private let camera: CameraFrameActor
    private let sceneChangeDetector: SceneChangeDetectionActor
    private let sceneDesc: SceneDescriptionActor
    private let screenCapture: ScreenCaptureActor
    private let screenChangeDetector: ScreenChangeDetectionActor
    private let screenDesc: ScreenDescriptionActor
    private let activeApp: ActiveAppActor
    private let axFocus: AXFocusActor
    private let turnDetector: TurnDetectorActor
    private let perceptionLog: PerceptionLogActor
    private let cognitiveCore: CognitiveCoreActor
    private let memoryWriteBack: MemoryWriteBackActor
    private let streamingTTS: StreamingTTSActor

    init() {
        let envPath = Self.resolveEnvPath()
        logger.notice("Resolved env path: \(envPath, privacy: .public)")

        let hub = EventHubActor()
        let cfg = ConfigActor(envFilePath: envPath)
        let reg = StateRegistryActor()
        let sup = ModuleSupervisorActor(eventHub: hub, stateRegistry: reg)
        let loggerActor = EventLoggerActor(eventHub: hub)
        let mic = MicrophoneCaptureActor(eventHub: hub)
        let dg = DeepgramStreamingActor(eventHub: hub, config: cfg, replayProvider: mic)
        let proj = TranscriptProjectionActor(eventHub: hub)
        let cameraActor = CameraFrameActor(eventHub: hub, config: cfg)
        let sceneChangeDetectorActor = SceneChangeDetectionActor(eventHub: hub, config: cfg)
        let sceneDescActor = SceneDescriptionActor(eventHub: hub, config: cfg)
        let screenCaptureActor = ScreenCaptureActor(eventHub: hub, config: cfg)
        let screenChangeDetectorActor = ScreenChangeDetectionActor(eventHub: hub, config: cfg)
        let screenDescActor = ScreenDescriptionActor(eventHub: hub, config: cfg)
        let activeAppActor = ActiveAppActor(eventHub: hub)
        let axFocusActor = AXFocusActor(eventHub: hub, config: cfg)
        let turnDetectorActor = TurnDetectorActor(eventHub: hub)
        let perceptionLogActor = PerceptionLogActor(eventHub: hub)
        let cognitiveCoreActor = CognitiveCoreActor(eventHub: hub, perceptionLog: perceptionLogActor, config: cfg)
        let memoryWriteBackActor = MemoryWriteBackActor(eventHub: hub,
                                                        memoryClient: SidecarMemoryClient(baseURL: SidecarMemoryClient.defaultBaseURL))
        let streamingTTSActor = StreamingTTSActor(eventHub: hub, config: cfg)

        self.eventHub = hub
        self.config = cfg
        self.stateRegistry = reg
        self.supervisor = sup
        self.eventLogger = loggerActor
        self.micCapture = mic
        self.deepgram = dg
        self.projection = proj
        self.camera = cameraActor
        self.sceneChangeDetector = sceneChangeDetectorActor
        self.sceneDesc = sceneDescActor
        self.screenCapture = screenCaptureActor
        self.screenChangeDetector = screenChangeDetectorActor
        self.screenDesc = screenDescActor
        self.activeApp = activeAppActor
        self.axFocus = axFocusActor
        self.turnDetector = turnDetectorActor
        self.perceptionLog = perceptionLogActor
        self.cognitiveCore = cognitiveCoreActor
        self.memoryWriteBack = memoryWriteBackActor
        self.streamingTTS = streamingTTSActor

        let vm = EventLogViewModel(eventHub: hub)
        _viewModel = StateObject(wrappedValue: vm)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { try? await sup.restart(mic.id) }
        }

        Task {
            await Self.bootstrap(
                sup: sup, eventLogger: loggerActor, mic: mic, dg: dg, proj: proj,
                camera: cameraActor, sceneChangeDetector: sceneChangeDetectorActor, sceneDesc: sceneDescActor,
                screenCapture: screenCaptureActor, screenChangeDetector: screenChangeDetectorActor,
                screenDesc: screenDescActor, activeApp: activeAppActor, axFocus: axFocusActor,
                turnDetector: turnDetectorActor,
                perceptionLog: perceptionLogActor, cognitiveCore: cognitiveCoreActor,
                memoryWriteBack: memoryWriteBackActor, streamingTTS: streamingTTSActor, vm: vm
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            EventLogView(viewModel: viewModel)
        }
    }

    private static func bootstrap(
        sup: ModuleSupervisorActor,
        eventLogger: EventLoggerActor,
        mic: MicrophoneCaptureActor,
        dg: DeepgramStreamingActor,
        proj: TranscriptProjectionActor,
        camera: CameraFrameActor,
        sceneChangeDetector: SceneChangeDetectionActor,
        sceneDesc: SceneDescriptionActor,
        screenCapture: ScreenCaptureActor,
        screenChangeDetector: ScreenChangeDetectionActor,
        screenDesc: ScreenDescriptionActor,
        activeApp: ActiveAppActor,
        axFocus: AXFocusActor,
        turnDetector: TurnDetectorActor,
        perceptionLog: PerceptionLogActor,
        cognitiveCore: CognitiveCoreActor,
        memoryWriteBack: MemoryWriteBackActor,
        streamingTTS: StreamingTTSActor,
        vm: EventLogViewModel
    ) async {
        let logger = Logger(subsystem: "com.banti.app", category: "Lifecycle")
        logger.notice("bootstrap entered")

        await sup.register(eventLogger, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(proj, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(dg, restartPolicy: .onFailure(maxRetries: 5, backoff: 1))
        await sup.register(mic, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [dg.id, proj.id])
        await sup.register(sceneDesc, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(sceneChangeDetector, restartPolicy: .onFailure(maxRetries: 3, backoff: 1), dependencies: [sceneDesc.id])
        await sup.register(camera, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [sceneChangeDetector.id])
        await sup.register(activeApp, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        // Registration order is LOAD-BEARING: screenDesc must subscribe before screenChangeDetector,
        // screenChangeDetector must subscribe before screenCapture starts publishing.
        await sup.register(screenDesc,           restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(screenChangeDetector, restartPolicy: .onFailure(maxRetries: 3, backoff: 1),
                           dependencies: [screenDesc.id])
        await sup.register(screenCapture,        restartPolicy: .onFailure(maxRetries: 3, backoff: 2),
                           dependencies: [screenChangeDetector.id])
        // AX permission won't change without user action in System Settings — no retry.
        await sup.register(axFocus, restartPolicy: .never)
        // Cognitive pipeline: perception log → turn detection → cognitive core → memory write-back + streaming TTS
        await sup.register(perceptionLog, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(turnDetector, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(cognitiveCore, restartPolicy: .onFailure(maxRetries: 3, backoff: 2),
                           dependencies: [perceptionLog.id, turnDetector.id])
        await sup.register(memoryWriteBack, restartPolicy: .onFailure(maxRetries: 3, backoff: 1),
                           dependencies: [cognitiveCore.id])
        await sup.register(streamingTTS, restartPolicy: .onFailure(maxRetries: 3, backoff: 1),
                           dependencies: [cognitiveCore.id])

        do {
            // vm.startListening() MUST come before sup.startAll() — ensures EventLogViewModel
            // is subscribed to all 10 event types before any module begins publishing.
            await vm.startListening()
            try await sup.startAll()
            logger.notice("bootstrap completed — pipeline running")
        } catch {
            logger.error("Pipeline failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run { vm.setError(error.localizedDescription) }
        }
    }

    private static func resolveEnvPath() -> String {
        let candidates: [String?] = [
            Bundle.main.path(forResource: ".env", ofType: nil),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".env").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/Code/banti/.env").path,
        ]
        for case let path? in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return candidates.compactMap({ $0 }).first ?? ".env"
    }
}
