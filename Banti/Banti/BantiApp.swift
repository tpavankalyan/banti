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
    @StateObject private var viewModel: TranscriptViewModel
    private let logger = Logger(subsystem: "com.banti.app", category: "Lifecycle")

    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let stateRegistry: StateRegistryActor
    private let supervisor: ModuleSupervisorActor
    private let micCapture: MicrophoneCaptureActor
    private let deepgram: DeepgramStreamingActor
    private let projection: TranscriptProjectionActor
    private let brain: BrainActor
    private let speech: SpeechActor
    private let camera: CameraFrameActor
    private let sceneDesc: SceneDescriptionActor

    init() {
        let envPath = Self.resolveEnvPath()
        logger.notice("Resolved env path: \(envPath, privacy: .public)")

        let hub = EventHubActor()
        let cfg = ConfigActor(envFilePath: envPath)
        let reg = StateRegistryActor()
        let sup = ModuleSupervisorActor(eventHub: hub, stateRegistry: reg)
        let mic = MicrophoneCaptureActor(eventHub: hub)
        let dg = DeepgramStreamingActor(eventHub: hub, config: cfg, replayProvider: mic)
        let proj = TranscriptProjectionActor(eventHub: hub)
        let brainActor = BrainActor(eventHub: hub, config: cfg)
        let speechActor = SpeechActor(eventHub: hub, config: cfg)
        let cameraActor = CameraFrameActor(eventHub: hub, config: cfg)
        let sceneDescActor = SceneDescriptionActor(eventHub: hub, config: cfg, replayProvider: cameraActor)

        self.eventHub = hub
        self.config = cfg
        self.stateRegistry = reg
        self.supervisor = sup
        self.micCapture = mic
        self.deepgram = dg
        self.projection = proj
        self.brain = brainActor
        self.speech = speechActor
        self.camera = cameraActor
        self.sceneDesc = sceneDescActor

        let vm = TranscriptViewModel(eventHub: hub)
        _viewModel = StateObject(wrappedValue: vm)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { try? await sup.restart(mic.id) }
        }

        Task {
            await Self.bootstrap(
                sup: sup, mic: mic, dg: dg, proj: proj,
                brain: brainActor, speech: speechActor,
                camera: cameraActor, sceneDesc: sceneDescActor, vm: vm
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            TranscriptView(viewModel: viewModel)
        }
    }

    private static func bootstrap(
        sup: ModuleSupervisorActor,
        mic: MicrophoneCaptureActor,
        dg: DeepgramStreamingActor,
        proj: TranscriptProjectionActor,
        brain: BrainActor,
        speech: SpeechActor,
        camera: CameraFrameActor,
        sceneDesc: SceneDescriptionActor,
        vm: TranscriptViewModel
    ) async {
        let logger = Logger(subsystem: "com.banti.app", category: "Lifecycle")
        logger.notice("bootstrap entered")

        // Projection must be subscribed before RawTranscriptEvents; mic must run after Deepgram
        // subscribes to AudioFrameEvent. Mic waits on both so topo order is never dg → mic → proj
        // (which would drop transcripts — hub drops events with no subscribers).
        await sup.register(proj, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(dg, restartPolicy: .onFailure(maxRetries: 5, backoff: 1))
        await sup.register(mic, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [dg.id, proj.id])
        await sup.register(brain, restartPolicy: .onFailure(maxRetries: 3, backoff: 2))
        await sup.register(speech, restartPolicy: .onFailure(maxRetries: 3, backoff: 2))
        // Camera pipeline — required start order: brain → sceneDesc → camera
        // brain must subscribe to SceneDescriptionEvent before sceneDesc starts publishing.
        // sceneDesc must subscribe to CameraFrameEvent before camera starts publishing.
        await sup.register(sceneDesc, restartPolicy: .onFailure(maxRetries: 3, backoff: 1), dependencies: [brain.id])
        await sup.register(camera,    restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [sceneDesc.id])

        do {
            // Subscribe before any module can publish TranscriptSegmentEvent (async handlers run
            // concurrently while startAll() is still progressing).
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
