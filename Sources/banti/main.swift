// Sources/banti/main.swift
import Foundation
import AppKit

// Shared components
let logger = Logger()
let deduplicator = Deduplicator()
let vision = LocalVision(logger: logger)

logger.log(source: "system", message: "banti starting...")

// Check Ollama availability, then start recheck timer
vision.checkAvailability()
vision.startRecheckTimer()

// Start AX reader
let axReader = AXReader(logger: logger)
axReader.start()

// Start camera capture
let cameraCapture = CameraCapture(logger: logger, deduplicator: deduplicator, vision: vision)
cameraCapture.start()

// Start screen capture (async)
let screenCapture = ScreenCapture(logger: logger, deduplicator: deduplicator, vision: vision)
Task {
    await screenCapture.start()
}

logger.log(source: "system", message: "banti running. Press Ctrl+C to stop.")
RunLoop.main.run()
