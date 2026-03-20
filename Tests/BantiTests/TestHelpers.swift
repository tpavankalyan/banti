// Tests/BantiTests/TestHelpers.swift
import XCTest
@testable import BantiCore

/// Actor-isolated mutable box — useful in async tests across all CorticalNode test files.
actor ActorBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
    func append(_ item: Any) where T == [BantiEvent] {
        value.append(item as! BantiEvent)
    }
    func appendString(_ item: String) where T == [String] {
        value.append(item)
    }
}
