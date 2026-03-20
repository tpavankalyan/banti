// Sources/BantiCore/SpeakerAttributor.swift
import Foundation

public struct SpeakerAttributor {
    public enum Source: Equatable {
        case human, selfEcho
    }

    public init() {}

    public func attribute(
        _ transcript: String,
        arrivedAt: Date = Date(),
        selfLog: SelfSpeechLog
    ) async -> Source {
        if await selfLog.isSelfEcho(transcript: transcript, arrivedAt: arrivedAt) {
            return .selfEcho
        }
        return .human
    }
}
