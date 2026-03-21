import Foundation

final class CameraLatestFrameBuffer: @unchecked Sendable {
    private var latest: Data?
    private let lock = NSLock()

    func store(_ jpeg: Data) {
        lock.withLock { latest = jpeg }
    }

    func take() -> Data? {
        lock.withLock {
            defer { latest = nil }
            return latest
        }
    }
}
