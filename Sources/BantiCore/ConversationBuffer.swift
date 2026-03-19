// Sources/BantiCore/ConversationBuffer.swift
import Foundation

public enum Speaker: String, Codable {
    case banti, human
}

public struct ConversationTurn: Codable {
    public let speaker: Speaker
    public let text: String
    public let timestamp: Date

    public init(speaker: Speaker, text: String, timestamp: Date = Date()) {
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }
}

public actor ConversationBuffer {
    private var turns: [ConversationTurn] = []
    private static let maxTurns = 30

    public func addBantiTurn(_ text: String) {
        append(ConversationTurn(speaker: .banti, text: text))
    }

    public func addHumanTurn(_ text: String) {
        append(ConversationTurn(speaker: .human, text: text))
    }

    public func recentTurns(limit: Int = 10) -> [ConversationTurn] {
        Array(turns.suffix(limit))
    }

    public func lastBantiUtterance() -> String? {
        turns.last(where: { $0.speaker == .banti })?.text
    }

    private func append(_ turn: ConversationTurn) {
        if turns.count >= Self.maxTurns { turns.removeFirst() }
        turns.append(turn)
    }
}
