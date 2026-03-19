// Sources/BantiCore/SelfModel.swift
import Foundation

public actor SelfModel {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let logger: Logger

    private static let reflectionIntervalNanoseconds: UInt64 = 600_000_000_000
    private var recentSnapshots: [String] = []
    private static let maxSnapshotBuffer = 300

    public init(context: PerceptionContext, sidecar: MemorySidecar, logger: Logger) {
        self.context = context
        self.sidecar = sidecar
        self.logger = logger
    }

    public func start() {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let snap = await self.context.snapshotJSON()
                await self.addSnapshot(snap)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SelfModel.reflectionIntervalNanoseconds)
                await self.reflect()
            }
        }
    }

    private func addSnapshot(_ snap: String) {
        if snap == "{}" { return }
        if recentSnapshots.count >= SelfModel.maxSnapshotBuffer {
            recentSnapshots.removeFirst()
        }
        recentSnapshots.append(snap)
    }

    private func reflect() async {
        guard await sidecar.isRunning else { return }
        guard !recentSnapshots.isEmpty else { return }

        struct ReflectBody: Encodable {
            let snapshots: [String]
        }

        let body = ReflectBody(snapshots: recentSnapshots)
        if let data = await sidecar.post(path: "/memory/reflect", body: body) {
            struct ReflectResponse: Decodable { let summary: String }
            if let response = try? JSONDecoder().decode(ReflectResponse.self, from: data) {
                logger.log(source: "memory", message: "reflection: \(response.summary)")
            }
        }
        recentSnapshots.removeAll()
    }
}
