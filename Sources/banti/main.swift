// Sources/banti/main.swift
import Foundation
import AppKit
import AVFoundation
import BantiCore

// Shared infrastructure
let logger = Logger()

logger.log(source: "system", message: "banti starting...")

// Perception context (still used by AudioRouter, SpeakerResolver, etc.)
let context = PerceptionContext()

// Start AX reader (accessibility side-channel)
let axReader = AXReader(logger: logger)
axReader.start()

// Phase 2 sensor cortices — each owns its own capture pipeline and LocalPerception
let visualCortex = VisualCortex.makeDefault(logger: logger)
let screenCortex = ScreenCortex.makeDefault(logger: logger)

// Audio pipeline
let audioRouter = AudioRouter(context: context, logger: logger)
Task { await audioRouter.configure() }

// Shared audio engine — must be created before either CartesiaSpeaker or MicrophoneCapture.
// CartesiaSpeaker.init (called inside MemoryEngine.init) attaches its playerNode to this engine.
// MicrophoneCapture.startCapture() then enables voice processing and starts the engine.
// This ordering gives macOS AEC a complete I/O graph to reference.
let sharedEngine = AVAudioEngine()

// Memory layer — init is synchronous; CartesiaSpeaker attaches playerNode to sharedEngine here.
// Must complete before micCapture.start() calls engine.start().
let memoryEngine = MemoryEngine(context: context, audioRouter: audioRouter, engine: sharedEngine, logger: logger)
Task {
    // Wire ScreenCortex self-echo filter before starting the graph
    await screenCortex.setBantiVoice(memoryEngine.bantiVoice)

    // Start cortical graph nodes via MemoryEngine
    let bus = await memoryEngine.eventBus
    await visualCortex.start(bus: bus)
    await screenCortex.start(bus: bus)
    await memoryEngine.start()
}

// Start mic after MemoryEngine.init so playerNode is in the graph before engine.start().
let soundClassifier = SoundClassifier(context: context, logger: logger)
let micCapture = MicrophoneCapture(engine: sharedEngine, dispatcher: audioRouter, soundClassifier: soundClassifier, logger: logger)
micCapture.start()

logger.log(source: "system", message: "banti running. Press Ctrl+C to stop.")

// SIGHUP hot-reload
signal(SIGHUP, SIG_IGN)
let sigHupSrc = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
sigHupSrc.setEventHandler {
    guard let config = NodeConfig.loadFromFile() else { return }
    Task {
        await memoryEngine.reloadPrompts(config: config)
    }
}
sigHupSrc.resume()

RunLoop.main.run()
