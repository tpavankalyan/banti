import Foundation

final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        frames.append(data)
        lock.unlock()
    }

    func drain() -> [Data] {
        lock.lock()
        let result = frames
        frames.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }
}
