import SwiftUI
import Combine

@main
struct BantiApp: App {
    @StateObject private var viewModel: TranscriptViewModel

    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let stateRegistry: StateRegistryActor
    private let supervisor: ModuleSupervisorActor
    private let micCapture: MicrophoneCaptureActor
    private let deepgram: DeepgramStreamingActor
    private let projection: TranscriptProjectionActor

    init() {
        let envPath = Bundle.main.path(forResource: ".env", ofType: nil)
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".env").path

        let hub = EventHubActor()
        let cfg = ConfigActor(envFilePath: envPath)
        let reg = StateRegistryActor()
        let sup = ModuleSupervisorActor(eventHub: hub, stateRegistry: reg)
        let mic = MicrophoneCaptureActor(eventHub: hub)
        let dg = DeepgramStreamingActor(eventHub: hub, config: cfg, replayProvider: mic)
        let proj = TranscriptProjectionActor(eventHub: hub)

        self.eventHub = hub
        self.config = cfg
        self.stateRegistry = reg
        self.supervisor = sup
        self.micCapture = mic
        self.deepgram = dg
        self.projection = proj

        let vm = TranscriptViewModel(eventHub: hub)
        _viewModel = StateObject(wrappedValue: vm)
    }

    var body: some Scene {
        WindowGroup {
            TranscriptView(viewModel: viewModel)
                .task { await registerAndStart() }
                .onReceive(
                    NSWorkspace.shared.notificationCenter
                        .publisher(for: NSWorkspace.didWakeNotification)
                ) { _ in
                    Task {
                        try? await supervisor.restart(micCapture.id)
                    }
                }
        }
    }

    private func registerAndStart() async {
        await supervisor.register(micCapture,
                                  restartPolicy: .onFailure(maxRetries: 3, backoff: 2))
        await supervisor.register(deepgram,
                                  restartPolicy: .onFailure(maxRetries: 5, backoff: 1))
        await supervisor.register(projection,
                                  restartPolicy: .onFailure(maxRetries: 3, backoff: 1))

        do {
            try await supervisor.startAll()
            await viewModel.startListening()
        } catch {
            print("Failed to start perception pipeline: \(error)")
        }
    }
}
