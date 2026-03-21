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
    private let eventLogger: EventLoggerActor
    private let micCapture: MicrophoneCaptureActor
    private let deepgram: DeepgramStreamingActor
    private let projection: TranscriptProjectionActor
    private let camera: CameraFrameActor
    private let sceneDesc: SceneDescriptionActor

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
        let sceneDescActor = SceneDescriptionActor(eventHub: hub, config: cfg, replayProvider: cameraActor)

        self.eventHub = hub
        self.config = cfg
        self.stateRegistry = reg
        self.supervisor = sup
        self.eventLogger = loggerActor
        self.micCapture = mic
        self.deepgram = dg
        self.projection = proj
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
                sup: sup, eventLogger: loggerActor, mic: mic, dg: dg, proj: proj,
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
        eventLogger: EventLoggerActor,
        mic: MicrophoneCaptureActor,
        dg: DeepgramStreamingActor,
        proj: TranscriptProjectionActor,
        camera: CameraFrameActor,
        sceneDesc: SceneDescriptionActor,
        vm: TranscriptViewModel
    ) async {
        let logger = Logger(subsystem: "com.banti.app", category: "Lifecycle")
        logger.notice("bootstrap entered")

        // Event logger registered first — subscribed before any module can publish.
        await sup.register(eventLogger, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        // Projection must subscribe to RawTranscriptEvent before mic starts.
        // Mic depends on both dg and proj so topo order is: proj → dg → mic.
        await sup.register(proj, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(dg, restartPolicy: .onFailure(maxRetries: 5, backoff: 1))
        await sup.register(mic, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [dg.id, proj.id])
        // Camera pipeline: sceneDesc must subscribe to CameraFrameEvent before camera starts.
        await sup.register(sceneDesc, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(camera, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [sceneDesc.id])

        do {
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
