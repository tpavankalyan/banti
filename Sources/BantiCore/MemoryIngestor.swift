// Sources/BantiCore/MemoryIngestor.swift
import Foundation

public actor MemoryIngestor {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let logger: Logger

    public static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
    public static let maxBufferSize = 100

    private var lastSnapshot: String = ""
    private var episodeBuffer: [String] = []

    public init(context: PerceptionContext, sidecar: MemorySidecar, logger: Logger) {
        self.context = context
        self.sidecar = sidecar
        self.logger = logger
    }

    public func start() {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: MemoryIngestor.pollIntervalNanoseconds)
                await self.ingestCycle()
            }
        }
    }

    public static func isDuplicate(_ snapshot: String, previous: String) -> Bool {
        snapshot == previous
    }

    public static func isEmpty(_ snapshot: String) -> Bool {
        snapshot.trimmingCharacters(in: .whitespaces).isEmpty || snapshot == "{}"
    }

    private func ingestCycle() async {
        guard await sidecar.isRunning else { return }

        let snapshot = await context.snapshotJSON()

        guard !MemoryIngestor.isEmpty(snapshot),
              !MemoryIngestor.isDuplicate(snapshot, previous: lastSnapshot) else { return }

        lastSnapshot = snapshot

        struct IngestBody: Encodable {
            let snapshot_json: String
            let wall_ts: String
        }

        let iso = ISO8601DateFormatter().string(from: Date())
        let body = IngestBody(snapshot_json: snapshot, wall_ts: iso)

        if let _ = await sidecar.post(path: "/memory/ingest", body: body) {
            if !episodeBuffer.isEmpty {
                episodeBuffer.removeAll()
            }
        } else {
            if episodeBuffer.count < MemoryIngestor.maxBufferSize {
                episodeBuffer.append(snapshot)
            }
        }
    }
}
