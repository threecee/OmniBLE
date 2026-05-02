//
//  HandoffStatePersistenceTests.swift
//  OmniBLETests
//
//  B.5 Issue #4: persistence helper tests.
//

import XCTest
@testable import OmniBLE

final class HandoffStatePersistenceTests: XCTestCase {

    // Use isolated UserDefaults suite per test so tests don't interfere.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "com.LoopKit.OmniBLE.HandoffStatePersistenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        HandoffStatePersistence.clear(from: defaults)
    }

    override func tearDown() async throws {
        HandoffStatePersistence.clear(from: defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRoundTrip_preservesPhoneDriver() {
        HandoffStatePersistence.save(.phoneDriver, to: defaults)
        let restored = HandoffStatePersistence.load(from: defaults)
        XCTAssertEqual(restored, .phoneDriver)
    }

    func testRoundTrip_preservesWatchDriver() {
        HandoffStatePersistence.save(.watchDriver, to: defaults)
        let restored = HandoffStatePersistence.load(from: defaults)
        XCTAssertEqual(restored, .watchDriver)
    }

    func testRoundTrip_preservesHandoffPending() {
        let id = UUID()
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        let pending = HandoffState.handoffPending(direction: .phoneToWatch,
                                                   transitionId: id,
                                                   deadline: deadline)
        HandoffStatePersistence.save(pending, to: defaults)
        let restored = HandoffStatePersistence.load(from: defaults)
        XCTAssertEqual(restored, pending)
    }

    func testLoad_returnsNilWhenEmpty() {
        let restored = HandoffStatePersistence.load(from: defaults)
        XCTAssertNil(restored)
    }

    func testLoad_returnsNilOnFormatVersionMismatch() throws {
        // Save a real state, then mutate the JSON to swap formatVersion
        HandoffStatePersistence.save(.phoneDriver, to: defaults)
        let key = "com.LoopKit.OmniBLE.persistedHandoffState"
        guard let data = defaults.data(forKey: key) else {
            return XCTFail("expected save to write data")
        }
        var decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        decoded["formatVersion"] = 99  // mismatch with currentFormatVersion (1)
        let mutated = try JSONSerialization.data(withJSONObject: decoded)
        defaults.set(mutated, forKey: key)

        let restored = HandoffStatePersistence.load(from: defaults)
        XCTAssertNil(restored,
                     "Mismatched formatVersion should produce nil — state machine falls back to initialState")
    }

    func testClear_removesPersistedState() {
        HandoffStatePersistence.save(.watchDriver, to: defaults)
        HandoffStatePersistence.clear(from: defaults)
        let restored = HandoffStatePersistence.load(from: defaults)
        XCTAssertNil(restored)
    }
}
