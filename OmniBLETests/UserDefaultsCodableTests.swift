//
//  UserDefaultsCodableTests.swift
//  OmniBLETests
//
//  B.8.1 mechanical /simplify: round-trip + missing-key + corrupt-data
//  coverage for UserDefaults+Codable extension.
//

import XCTest
@testable import OmniBLE

final class UserDefaultsCodableTests: XCTestCase {

    private struct TestPayload: Codable, Equatable {
        let version: Int
        let label: String
    }

    private static let suiteName = "B8.1.UserDefaultsCodableTests"

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRoundTripsCodableValue() {
        let original = TestPayload(version: 7, label: "alpha")
        defaults.set(codable: original, forKey: "test.key")
        let decoded = defaults.codableValue(forKey: "test.key", as: TestPayload.self)
        XCTAssertEqual(decoded, original)
    }

    func testReturnsNilForMissingKey() {
        let decoded = defaults.codableValue(forKey: "test.absent", as: TestPayload.self)
        XCTAssertNil(decoded)
    }

    func testReturnsNilForCorruptData() {
        defaults.set(Data([0xFF, 0xFE]), forKey: "test.corrupt")
        let decoded = defaults.codableValue(forKey: "test.corrupt", as: TestPayload.self)
        XCTAssertNil(decoded)
    }
}
