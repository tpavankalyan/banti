// Sources/BantiCore/ProactiveIntroducer.swift
import Foundation

public actor ProactiveIntroducer {
    private let logger: Logger
    public static let firstPromptThreshold: Double = 30.0
    public static let secondPromptThreshold: Double = 60.0

    private struct PersonTracking {
        var firstSeen: Date
        var hasPromptedOnce: Bool = false
        var hasPromptedTwice: Bool = false
    }

    private var tracking: [String: PersonTracking] = [:]

    public init(logger: Logger) {
        self.logger = logger
    }

    public func personSeen(_ personID: String, name: String?) {
        guard name == nil else {
            tracking.removeValue(forKey: personID)
            return
        }

        if tracking[personID] == nil {
            tracking[personID] = PersonTracking(firstSeen: Date())
        }

        guard var t = tracking[personID] else { return }

        if ProactiveIntroducer.shouldPrompt(
            firstSeen: t.firstSeen,
            hasPromptedOnce: t.hasPromptedOnce,
            hasPromptedTwice: t.hasPromptedTwice
        ) {
            if !t.hasPromptedOnce {
                t.hasPromptedOnce = true
                logger.log(source: "memory",
                    message: "I noticed someone new nearby. What's their name?")
            } else if !t.hasPromptedTwice {
                t.hasPromptedTwice = true
                logger.log(source: "memory",
                    message: "Still haven't caught their name — feel free to introduce them.")
            }
            tracking[personID] = t
        }
    }

    public func isTracking(_ personID: String) -> Bool {
        tracking[personID] != nil
    }

    public static func shouldPrompt(
        firstSeen: Date,
        hasPromptedOnce: Bool,
        hasPromptedTwice: Bool,
        now: Date = Date()
    ) -> Bool {
        if hasPromptedTwice { return false }
        let elapsed = now.timeIntervalSince(firstSeen)
        if !hasPromptedOnce { return elapsed >= firstPromptThreshold }
        return elapsed >= secondPromptThreshold
    }
}
