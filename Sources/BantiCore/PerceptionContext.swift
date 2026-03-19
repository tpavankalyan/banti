// Sources/BantiCore/PerceptionContext.swift
import Foundation

public actor PerceptionContext {
    public var face:     FaceState?
    public var emotion:  EmotionState?
    public var pose:     PoseState?
    public var gesture:  GestureState?
    public var screen:   ScreenState?
    public var activity: ActivityState?
    public var speech:   SpeechState?
    public var voiceEmotion: VoiceEmotionState?
    public var sound:    SoundState?

    public init() {}

    public func update(_ observation: PerceptionObservation) {
        switch observation {
        case .face(let s):     face = s
        case .pose(let s):     pose = s
        case .emotion(let s):  emotion = s
        case .activity(let s): activity = s
        case .gesture(let s):  gesture = s
        case .screen(let s):   screen = s
        case .speech(let s):   speech = s
        case .voiceEmotion(let s): voiceEmotion = s
        case .sound(let s):    sound = s
        }
    }

    /// Serialize non-nil fields to a compact JSON string for logging.
    public func snapshotJSON() -> String {
        var dict: [String: Any] = [:]
        if let f = face     { dict["face"]     = encodable(f) }
        if let e = emotion  { dict["emotion"]  = encodable(e) }
        if let p = pose     { dict["pose"]     = encodable(p) }
        if let g = gesture  { dict["gesture"]  = encodable(g) }
        if let s = screen   { dict["screen"]   = encodable(s) }
        if let a = activity { dict["activity"] = encodable(a) }
        if let sp = speech  { dict["speech"]   = encodable(sp) }
        if let ve = voiceEmotion { dict["voiceEmotion"] = encodable(ve) }
        if let so = sound   { dict["sound"]    = encodable(so) }
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// Called from main.swift after wiring. Timer fires every 2 seconds.
    nonisolated public func startSnapshotTimer(logger: Logger) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let json = await self.snapshotJSON()
                if json != "{}" {
                    logger.log(source: "perception", message: json)
                }
            }
        }
    }

    // Encode any Codable value to a JSON-compatible dictionary
    private func encodable<T: Codable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return obj
    }
}
