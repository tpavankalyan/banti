// Sources/BantiCore/SelfSpeechLog.swift
import Foundation

public actor SelfSpeechLog {
    private struct Entry {
        let normalizedText: String
        let registeredAt: Date
    }

    private var entries: [Entry] = []
    private var lastPlaybackEndedAt: Date?
    public private(set) var isCurrentlyPlaying: Bool = false

    private static let maxEntries = 30
    private static let entryTTLSeconds = 120.0
    private static let tailSeconds = 5.0
    private static let jaccardThreshold = 0.6
    private static let suppressMinWords = 5

    // MARK: - Public API

    public func register(text: String) {
        isCurrentlyPlaying = true
        purgeStale()
        let normalized = Self.normalize(text)
        if entries.count >= Self.maxEntries { entries.removeFirst() }
        entries.append(Entry(normalizedText: normalized, registeredAt: Date()))
    }

    public func markPlaybackEnded() {
        guard isCurrentlyPlaying else { return }
        isCurrentlyPlaying = false
        lastPlaybackEndedAt = Date()
    }

    public func isSelfEcho(transcript: String, arrivedAt: Date = Date()) -> Bool {
        purgeStale()
        let inTail = lastPlaybackEndedAt.map {
            arrivedAt.timeIntervalSince($0) <= Self.tailSeconds
        } ?? false
        let playbackGate = isCurrentlyPlaying || inTail
        guard playbackGate else { return false }

        // Conservative: gate active but no entries (race/cold-start edge case)
        if entries.isEmpty { return true }

        let normalized = Self.normalize(transcript)
        return entries.contains {
            Self.jaccard(normalized, $0.normalizedText) >= Self.jaccardThreshold
        }
    }

    public func suppressSelfEcho(in text: String) -> String {
        purgeStale()
        guard !entries.isEmpty else { return text }

        let normalizedInput = Self.normalize(text)
        var normalizedResult = normalizedInput
        var didSuppress = false

        for entry in entries {
            let phrase = entry.normalizedText
            guard phrase.split(separator: " ").count >= Self.suppressMinWords else { continue }
            if normalizedResult.contains(phrase) {
                normalizedResult = normalizedResult.replacingOccurrences(of: phrase, with: " ")
                didSuppress = true
            }
        }

        guard didSuppress else { return text }

        return normalizedResult
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Static helpers (public for testability)

    public static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .punctuationCharacters).joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func jaccard(_ a: String, _ b: String) -> Double {
        let setA = Set(a.split(separator: " ").map(String.init))
        let setB = Set(b.split(separator: " ").map(String.init))
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    // MARK: - Private

    private func purgeStale() {
        let cutoff = Date().addingTimeInterval(-Self.entryTTLSeconds)
        entries.removeAll { $0.registeredAt < cutoff }
    }
}
