// Sources/banti/Logger.swift
import Foundation

final class Logger {
    private let queue = DispatchQueue(label: "banti.logger")
    private let output: (String) -> Void
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(output: @escaping (String) -> Void = { print($0) }) {
        self.output = output
    }

    func log(source: String, message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = self.formatter.string(from: Date())
            self.output("[\(timestamp)] [source: \(source)] \(message)")
        }
    }
}
