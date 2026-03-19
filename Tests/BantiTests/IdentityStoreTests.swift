// Tests/BantiTests/IdentityStoreTests.swift
import XCTest
@testable import BantiCore

final class IdentityStoreTests: XCTestCase {

    func testStoreStartsEmpty() async {
        let store = IdentityStore()
        let name = await store.name(forPersonID: "p_001")
        XCTAssertNil(name)
    }

    func testSetNameCanBeRetrieved() async {
        let store = IdentityStore()
        await store.setName("Alice", forPersonID: "p_001")
        let name = await store.name(forPersonID: "p_001")
        XCTAssertEqual(name, "Alice")
    }

    func testSetNameOverwritesPrevious() async {
        let store = IdentityStore()
        await store.setName("Alice", forPersonID: "p_001")
        await store.setName("Alicia", forPersonID: "p_001")
        let name = await store.name(forPersonID: "p_001")
        XCTAssertEqual(name, "Alicia")
    }

    func testClearRemovesAllEntries() async {
        let store = IdentityStore()
        await store.setName("Bob", forPersonID: "p_002")
        await store.clear()
        let name = await store.name(forPersonID: "p_002")
        XCTAssertNil(name)
    }
}
