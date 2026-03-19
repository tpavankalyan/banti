// Sources/BantiCore/IdentityStore.swift
import Foundation

public actor IdentityStore {
    private var cache: [String: String] = [:]

    public init() {}

    public func name(forPersonID personID: String) -> String? {
        cache[personID]
    }

    public func setName(_ name: String, forPersonID personID: String) {
        cache[personID] = name
    }

    public func clear() {
        cache.removeAll()
    }
}
