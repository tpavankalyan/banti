import Foundation

final class ScreenLatestFrameBuffer: @unchecked Sendable {
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
