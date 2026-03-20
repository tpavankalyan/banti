// Sources/BantiCore/PerceptionRouter.swift
import Foundation
import Vision

public actor PerceptionRouter: PerceptionDispatcher {
    private var lastFired: [String: Date] = [:]
    private let context: PerceptionContext
    private let logger: Logger
    private var hume:     HumeEmotionAnalyzer?
    private var activity: GPT4oActivityAnalyzer?
    private var gesture:  GPT4oGestureAnalyzer?
    private var screen:   GPT4oScreenAnalyzer?
    private var faceIdentifier: FaceIdentifier?
    private var bantiVoice: BantiVoice?
    private var bus: EventBus?

    public init(context: PerceptionContext, logger: Logger) {
        self.context = context
        self.logger = logger
    }

    /// Configure cloud analyzers from environment variables. Call from main.swift.
    public func configure() {
        let env = ProcessInfo.processInfo.environment
        if let key = env["HUME_API_KEY"] {
            hume = HumeEmotionAnalyzer(apiKey: key, logger: logger)
        } else {
            logger.log(source: "system", message: "[warn] HUME_API_KEY missing — emotion analysis disabled")
        }
        if let key = env["OPENAI_API_KEY"] {
            activity = GPT4oActivityAnalyzer(apiKey: key, logger: logger)
            gesture  = GPT4oGestureAnalyzer(apiKey: key, logger: logger)
            screen   = GPT4oScreenAnalyzer(apiKey: key, logger: logger)
        } else {
            logger.log(source: "system", message: "[warn] OPENAI_API_KEY missing — activity, gesture, screen analysis disabled")
        }
    }

    /// Called by LocalPerception after each frame is analyzed.
    public func dispatch(jpegData: Data, source: String, events: [PerceptionEvent]) async {
        // Update face and pose state directly from local detections (no cloud needed)
        for event in events {
            if case .faceDetected(let obs) = event {
                let state = FaceState(boundingBox: obs.boundingBox,
                                      landmarksDetected: obs.landmarks != nil,
                                      updatedAt: Date())
                await context.update(.face(state))
                if let b = bus {
                    let person = await context.person
                    let payload = FacePayload(
                        boundingBox: state.boundingBox,
                        personID: person?.id,
                        personName: person?.name,
                        confidence: person?.confidence ?? 1.0
                    )
                    let event = BantiEvent(source: "visual_cortex", topic: "sensor.visual",
                                          surprise: 0.5, payload: .faceUpdate(payload))
                    await b.publish(event, topic: "sensor.visual")
                }
            }
            if case .bodyPoseDetected(let obs) = event {
                let bodyPoints = extractBodyPoints(obs)
                let state = PoseState(bodyPoints: bodyPoints, handPoints: nil, updatedAt: Date())
                await context.update(.pose(state))
            }
        }

        // Dispatch cloud analyzers (throttled, non-blocking)
        let hasFace   = events.contains { if case .faceDetected   = $0 { return true }; return false }
        let hasHuman  = events.contains { if case .humanPresent   = $0 { return true }; return false }
        let hasBody   = events.contains { if case .bodyPoseDetected = $0 { return true }; return false }
        let hasHand   = events.contains { if case .handPoseDetected = $0 { return true }; return false }
        let hasText   = events.contains { if case .textRecognized = $0 { return true }; return false }

        // Note: shouldFire/markFired are synchronous actor-isolated methods — no await needed within dispatch
        if hasFace, let analyzer = hume, shouldFire(analyzerName: "hume", throttleSeconds: 2) {
            markFired(analyzerName: "hume")
            Task { if let obs = await analyzer.analyze(jpegData: jpegData, events: events) { await self.context.update(obs) } }
        }

        if (hasFace || hasHuman) && source == "camera", let analyzer = activity,
           shouldFire(analyzerName: "activity", throttleSeconds: 5) {
            markFired(analyzerName: "activity")
            Task { if let obs = await analyzer.analyze(jpegData: jpegData, events: events) { await self.context.update(obs) } }
        }

        if (hasBody || hasHand), let analyzer = gesture, shouldFire(analyzerName: "gesture", throttleSeconds: 3) {
            markFired(analyzerName: "gesture")
            Task { if let obs = await analyzer.analyze(jpegData: jpegData, events: events) { await self.context.update(obs) } }
        }

        if hasText && source == "screen", let analyzer = screen, shouldFire(analyzerName: "screen", throttleSeconds: 4) {
            markFired(analyzerName: "screen")
            let voice = bantiVoice
            Task {
                guard let obs = await analyzer.analyze(jpegData: nil, events: events) else { return }
                if case .screen(let state) = obs, let v = voice {
                    let rawText = state.ocrLines.joined(separator: "\n")
                    let cleaned = await v.suppressSelfEcho(in: rawText)
                    let cleanedLines = cleaned.components(separatedBy: "\n").filter { !$0.isEmpty }
                    let cleanedInterp = await v.suppressSelfEcho(in: state.interpretation)
                    let filteredState = ScreenState(ocrLines: cleanedLines,
                                                    interpretation: cleanedInterp,
                                                    updatedAt: state.updatedAt)
                    await self.context.update(.screen(filteredState))
                    if let b = await self.bus {
                        let payload = ScreenPayload(ocrLines: filteredState.ocrLines,
                                                    interpretation: filteredState.interpretation)
                        let event = BantiEvent(source: "screen_cortex", topic: "sensor.screen",
                                               surprise: 0.6, payload: .screenUpdate(payload))
                        await b.publish(event, topic: "sensor.screen")
                    }
                } else {
                    await self.context.update(obs)
                    if case .screen(let s) = obs, let b = await self.bus {
                        let payload = ScreenPayload(ocrLines: s.ocrLines, interpretation: s.interpretation)
                        let event = BantiEvent(source: "screen_cortex", topic: "sensor.screen",
                                               surprise: 0.6, payload: .screenUpdate(payload))
                        await b.publish(event, topic: "sensor.screen")
                    }
                }
            }
        }

        // Dispatch FaceIdentifier (throttled 5s)
        if let identifier = faceIdentifier {
            if shouldFire(analyzerName: "faceIdentifier", throttleSeconds: 5) {
                markFired(analyzerName: "faceIdentifier")
                let faceObs: VNFaceObservation? = events.compactMap { event -> VNFaceObservation? in
                    if case .faceDetected(let obs) = event { return obs }
                    return nil
                }.first
                if let obs = faceObs {
                    let capturedJpeg = jpegData
                    Task { await identifier.dispatch(jpegData: capturedJpeg, faceObservation: obs) }
                }
            }
        }
    }

    // MARK: - FaceIdentifier

    public func setFaceIdentifier(_ identifier: FaceIdentifier) {
        faceIdentifier = identifier
    }

    var hasFaceIdentifier: Bool { faceIdentifier != nil }

    // MARK: - BantiVoice (screen self-echo filter)

    public func setBantiVoice(_ voice: BantiVoice) {
        bantiVoice = voice
    }

    public func setBus(_ bus: EventBus) {
        self.bus = bus
    }

    // MARK: - Throttle helpers (internal for testability)

    public func shouldFire(analyzerName: String, throttleSeconds: Double) -> Bool {
        guard let last = lastFired[analyzerName] else { return true }
        return Date().timeIntervalSince(last) >= throttleSeconds
    }

    public func markFired(analyzerName: String) {
        lastFired[analyzerName] = Date()
    }

    public func setLastFired(analyzerName: String, date: Date) {
        lastFired[analyzerName] = date
    }

    // MARK: - Keypoint extraction helpers

    private func extractBodyPoints(_ obs: VNHumanBodyPoseObservation) -> [String: CGPoint] {
        var points: [String: CGPoint] = [:]
        for joint in VNHumanBodyPoseObservation.JointName.allJoints {
            if let p = try? obs.recognizedPoint(joint), p.confidence > 0.3 {
                points[joint.rawValue.rawValue] = CGPoint(x: p.x, y: p.y)
            }
        }
        return points
    }
}
