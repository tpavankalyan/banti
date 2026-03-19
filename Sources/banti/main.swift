// Sources/banti/main.swift
import Foundation
import AppKit
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

let soundClassifier = SoundClassifier(context: context, logger: logger)
let micCapture = MicrophoneCapture(dispatcher: audioRouter, soundClassifier: soundClassifier, logger: logger)
micCapture.start()

// Memory layer
let memoryEngine = MemoryEngine(context: context, audioRouter: audioRouter, logger: logger)
Task {
    let fi = await memoryEngine.faceIdentifier
    await router.setFaceIdentifier(fi)
    await memoryEngine.start()
}

logger.log(source: "system", message: "banti running. Press Ctrl+C to stop.")
RunLoop.main.run()
