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
    private let capacity: Int
    private var buffer: [ConversationTurn?]
    private var head: Int = 0    // next write index
    private var count: Int = 0   // number of valid entries

    public init(capacity: Int = 60) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    public func addBantiTurn(_ text: String) {
        append(ConversationTurn(speaker: .banti, text: text))
    }

    public func addHumanTurn(_ text: String) {
        append(ConversationTurn(speaker: .human, text: text))
    }

    public func recentTurns(limit: Int = 10) -> [ConversationTurn] {
        let n = min(limit, count)
        var result: [ConversationTurn] = []
        let startOffset = count - n
        for i in 0..<n {
            let idx = ((head - count) + startOffset + i) % capacity
            if let turn = buffer[(idx + capacity) % capacity] {
                result.append(turn)
            }
        }
        return result
    }

    public func lastBantiUtterance() -> String? {
        // Scan from most recent to oldest
        for i in 0..<count {
            let idx = ((head - 1 - i) % capacity + capacity) % capacity
            if let turn = buffer[idx], turn.speaker == .banti {
                return turn.text
            }
        }
        return nil
    }

    private func append(_ turn: ConversationTurn) {
        buffer[head % capacity] = turn
        head += 1
        count = min(count + 1, capacity)
    }
}
