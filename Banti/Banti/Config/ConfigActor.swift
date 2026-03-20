import Foundation

struct ConfigError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

actor ConfigActor {
    private let values: [String: String]

    init(content: String) {
        self.values = Self.parse(content)
    }

    init(envFilePath: String) {
        if let content = try? String(contentsOfFile: envFilePath, encoding: .utf8) {
            self.values = Self.parse(content)
        } else {
            self.values = [:]
        }
    }

    private nonisolated static func parse(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            var keyValue = trimmed
            if keyValue.hasPrefix("export ") {
                keyValue = String(keyValue.dropFirst(7))
            }
            guard let eqIndex = keyValue.firstIndex(of: "=") else { continue }
            let key = String(keyValue[keyValue.startIndex..<eqIndex])
                .trimmingCharacters(in: .whitespaces)
            let value = String(keyValue[keyValue.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    func value(for key: String) -> String? {
        values[key] ?? ProcessInfo.processInfo.environment[key]
    }

    func require(_ key: String) throws -> String {
        if let val = values[key] { return val }
        if let env = ProcessInfo.processInfo.environment[key] { return env }
        throw ConfigError(message: "Missing required config key: \(key)")
    }
}
