// Sources/BantiCore/MemoryTypes.swift
import Foundation

// MARK: - PersonState

public struct PersonState: Codable {
    public let id: String
    public let name: String?
    public let confidence: Float
    public let updatedAt: Date

    public init(id: String, name: String?, confidence: Float, updatedAt: Date) {
        self.id = id
        self.name = name
        self.confidence = confidence
        self.updatedAt = updatedAt
    }
}

// MARK: - PersonRecord

public struct PersonRecord {
    public let id: String
    public let displayName: String?
    public let mem0UserID: String
    public let firstSeen: Date
    public let lastSeen: Date

    public init(id: String, displayName: String?, mem0UserID: String,
                firstSeen: Date, lastSeen: Date) {
        self.id = id
        self.displayName = displayName
        self.mem0UserID = mem0UserID
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

// MARK: - MemoryAction

public enum MemoryAction {
    case introduceYourself(personID: String)
    case correction(wrongName: String, correctName: String)
}

// MARK: - MemoryResponse

public struct MemoryResponse {
    public let answer: String
    public let sources: [String]

    public init(answer: String, sources: [String] = []) {
        self.answer = answer
        self.sources = sources
    }
}
