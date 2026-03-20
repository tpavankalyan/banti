// Sources/banti/main.swift
import Foundation
import AppKit
import AVFoundation
import BantiCore

// Shared infrastructure
let logger = Logger()

logger.log(source: "system", message: "banti starting...")

// Perception pipeline
let context = PerceptionContext()
let router  = PerceptionRouter(context: context, logger: logger)

// Configure cloud analyzers from environment variables
Task { await router.configure() }

let localPerception = LocalPerception(dispatcher: router)

// Start snapshot logging (every 2s)
context.startSnapshotTimer(logger: logger)

// Start AX reader (accessibility side-channel)
let axReader = AXReader(logger: logger)
axReader.start()

// Start camera capture
let deduplicator = Deduplicator()
let cameraCapture = CameraCapture(logger: logger, deduplicator: deduplicator, frameProcessor: localPerception)
cameraCapture.start()

// Start screen capture (async)
let screenDeduplicator = Deduplicator()
let screenCapture = ScreenCapture(logger: logger, deduplicator: screenDeduplicator, frameProcessor: localPerception)
Task {
    await screenCapture.start()
}

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
    let fi = await memoryEngine.faceIdentifier
    await router.setFaceIdentifier(fi)
    await router.setBantiVoice(memoryEngine.bantiVoice)
    await router.setBus(memoryEngine.eventBus)
    await memoryEngine.start()
}

// Start mic after MemoryEngine.init so playerNode is in the graph before engine.start().
let soundClassifier = SoundClassifier(context: context, logger: logger)
let micCapture = MicrophoneCapture(engine: sharedEngine, dispatcher: audioRouter, soundClassifier: soundClassifier, logger: logger)
micCapture.start()

logger.log(source: "system", message: "banti running. Press Ctrl+C to stop.")
RunLoop.main.run()
