// BantiTests/Helpers/MockScreenFrameDifferencer.swift
import Foundation
@testable import Banti

/// Returns a pre-programmed sequence of distances. Repeats last value once exhausted.
/// Pass `nil` to simulate the first-frame case (no prior reference).
actor MockScreenFrameDifferencer: ScreenFrameDifferencer {
    private var distances: [Float?]
    private var index = 0

    init(_ distances: [Float?]) {
        self.distances = distances
    }

    func distance(from jpeg: Data) throws -> Float? {
        let d = distances[min(index, distances.count - 1)]
        index += 1
        return d
    }
}
