// Sources/BantiCore/SelfModel.swift
import Foundation

public actor SelfModel {
    private let sidecar: MemorySidecar
    private let logger: Logger

    private static let reflectionIntervalNanoseconds: UInt64 = 600_000_000_000
    private var episodeBuffer: [String] = []
    private static let maxEpisodes = 20
    private var reflectionTask: Task<Void, Never>?

    public init(sidecar: MemorySidecar, logger: Logger) {
        self.sidecar = sidecar
        self.logger = logger
    }

    // Called from the bus subscription
    func handleEpisodeBound(_ episode: EpisodePayload) {
        episodeBuffer.append(episode.text)
        if episodeBuffer.count > SelfModel.maxEpisodes {
            episodeBuffer.removeFirst()
        }
    }

    // Wire up to EventBus and start periodic reflection
    public func start(bus: EventBus) async {
        await bus.subscribe(topic: "episode.bound") { [weak self] event in
            guard case .episodeBound(let episode) = event.payload else { return }
            await self?.handleEpisodeBound(episode)
        }
        reflectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SelfModel.reflectionIntervalNanoseconds)
                await self?.reflect()
            }
        }
    }

    private func reflect() async {
        guard await sidecar.isRunning else { return }
        guard !episodeBuffer.isEmpty else { return }
        let snapshots = episodeBuffer
        let summary = await sidecar.reflect(snapshots: snapshots)
        logger.log(source: "memory", message: "reflection: \(summary)")
        episodeBuffer.removeAll()
    }

    deinit {
        reflectionTask?.cancel()
    }
}
