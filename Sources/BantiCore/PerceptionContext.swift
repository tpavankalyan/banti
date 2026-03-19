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
    public var person:   PersonState?

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
        case .person(let s):   person = s
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
        if let pe = person  { dict["person"]   = encodable(pe) }
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    nonisolated public func startSnapshotTimer(logger: Logger) {}

    // Encode any Codable value to a JSON-compatible dictionary
    private func encodable<T: Codable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return obj
    }
}
