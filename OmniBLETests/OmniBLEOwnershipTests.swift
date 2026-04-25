import XCTest
@testable import OmniBLE

@MainActor
final class OmniBLEOwnershipTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "OmniBLEOwnershipTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - 1, 2: Initial state

    func test1_InitialStateIsDriverWhenRolePhone() {
        let ownership = OmniBLEOwnership(role: .phone, appGroupDefaults: defaults)
        XCTAssertTrue(ownership.iAmDriver)
    }

    func test2_InitialStateIsNotDriverWhenRoleWatch() {
        let ownership = OmniBLEOwnership(role: .watch, appGroupDefaults: defaults)
        XCTAssertFalse(ownership.iAmDriver)
    }

    // MARK: - 3-6: Transitions trigger acquire/release

    func test3_TransitionToWatchDriverFromPhoneRoleReleasesBLE() {
        let mock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(role: .phone, pumpManager: mock, appGroupDefaults: defaults)
        ownership.update(state: .watchDriver)
        XCTAssertEqual(mock.disconnectCallCount, 1)
        XCTAssertEqual(mock.connectCallCount, 0)
    }

    func test4_TransitionToWatchDriverFromWatchRoleAcquiresBLE() {
        let mock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(role: .watch, pumpManager: mock, appGroupDefaults: defaults)
        ownership.update(state: .watchDriver)
        XCTAssertEqual(mock.connectCallCount, 1)
        XCTAssertEqual(mock.disconnectCallCount, 0)
    }

    func test5_TransitionToPhoneDriverFromPhoneRoleAcquiresBLE() {
        let mock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(
            role: .phone, pumpManager: mock, appGroupDefaults: defaults,
            initialState: .watchDriver
        )
        ownership.update(state: .phoneDriver)
        XCTAssertEqual(mock.connectCallCount, 1)
        XCTAssertEqual(mock.disconnectCallCount, 0)
    }

    func test6_TransitionToPhoneDriverFromWatchRoleReleasesBLE() {
        let mock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(
            role: .watch, pumpManager: mock, appGroupDefaults: defaults,
            initialState: .watchDriver
        )
        ownership.update(state: .phoneDriver)
        XCTAssertEqual(mock.disconnectCallCount, 1)
        XCTAssertEqual(mock.connectCallCount, 0)
    }

    // MARK: - 7, 8: No-op transitions

    func test7_NoActionWhenStateUnchanged() {
        let mock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(role: .phone, pumpManager: mock, appGroupDefaults: defaults)
        ownership.update(state: .phoneDriver)
        ownership.update(state: .phoneDriver)
        XCTAssertEqual(mock.connectCallCount, 0)
        XCTAssertEqual(mock.disconnectCallCount, 0)
    }

    func test8_HandoffPendingDoesNotChangeOwnership() {
        let mock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(role: .phone, pumpManager: mock, appGroupDefaults: defaults)
        ownership.update(state: .handoffPending(direction: .phoneToWatch,
                                                  transitionId: UUID(),
                                                  deadline: Date().addingTimeInterval(30)))
        XCTAssertEqual(mock.connectCallCount, 0)
        XCTAssertEqual(mock.disconnectCallCount, 0)
    }

    // MARK: - 9, 10: Payload caching + persistence

    func test9_CachePayloadStoresInAppGroup() {
        let ownership = OmniBLEOwnership(role: .phone, appGroupDefaults: defaults)
        ownership.cachePayload(makeTestPayload())
        XCTAssertNotNil(defaults.data(forKey: "com.LoopKit.OmniBLE.cachedHandoffPayload"))
    }

    func test10_CachedPayloadSurvivesReinit() {
        let ownership1 = OmniBLEOwnership(role: .phone, appGroupDefaults: defaults)
        let payload = makeTestPayload()
        ownership1.cachePayload(payload)

        let ownership2 = OmniBLEOwnership(role: .phone, appGroupDefaults: defaults)
        XCTAssertEqual(ownership2.cachedPayload?.podSerial, payload.podSerial)
    }

    // MARK: - 11-13: Acquire BLE + payload restoration

    func test11_AcquireBLEHydratesPodStateFromCachedPayload() throws {
        let mock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(role: .watch, pumpManager: mock, appGroupDefaults: defaults)
        // Make a payload with a real serialized PodState so decode succeeds.
        let realPodState = PodState(
            address: 0x1234,
            ltk: Data(repeating: 0xAB, count: 16),
            firmwareVersion: "1.0",
            bleFirmwareVersion: "1.0",
            lotNo: UInt32(1),
            lotSeq: UInt32(1),
            productId: UInt8(0),
            bleIdentifier: "TEST_BLE_UUID",
            insulinType: .humalog
        )
        let payload = try OmniBLEHandoffPayload(podState: realPodState)
        ownership.cachePayload(payload)
        ownership.update(state: .watchDriver)
        XCTAssertEqual(mock.restoredPodStates.count, 1)
        XCTAssertEqual(mock.connectCallCount, 1)
    }

    func test12_AcquireBLEUsesExistingStateWhenNoCachedPayload() {
        let mock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(role: .watch, pumpManager: mock, appGroupDefaults: defaults)
        ownership.update(state: .watchDriver)
        XCTAssertEqual(mock.restoredPodStates.count, 0, "No cached payload, no restoration")
        XCTAssertEqual(mock.connectCallCount, 1, "Still attempts to connect")
    }

    func test13_AcquireBLESkipsWhenPayloadExpired() throws {
        let mock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(role: .watch, pumpManager: mock, appGroupDefaults: defaults)
        let realPodState = PodState(
            address: 0x1234,
            ltk: Data(repeating: 0xAB, count: 16),
            firmwareVersion: "1.0",
            bleFirmwareVersion: "1.0",
            lotNo: UInt32(1),
            lotSeq: UInt32(1),
            productId: UInt8(0),
            bleIdentifier: "TEST_BLE_UUID",
            insulinType: .humalog
        )
        let expired = try OmniBLEHandoffPayload(
            podState: realPodState,
            validUntil: Date(timeIntervalSinceNow: -60)   // 60s ago
        )
        ownership.cachePayload(expired)
        ownership.update(state: .watchDriver)
        XCTAssertEqual(mock.restoredPodStates.count, 0, "Expired payload should NOT be restored")
        XCTAssertEqual(mock.connectCallCount, 1, "Still attempts connect")
    }

    // MARK: - 14: Wiring bug case

    func test14_AcquireBLEWithoutPumpManagerLogsErrorNoCrash() {
        let ownership = OmniBLEOwnership(role: .watch, pumpManager: nil, appGroupDefaults: defaults)
        ownership.update(state: .watchDriver)
        // No assertion beyond "no crash" — log inspection is out of scope.
    }

    // MARK: - 15: Recovering state

    func test15_RecoveringStateUsesLastKnownOwner() {
        let mock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(
            role: .watch, pumpManager: mock, appGroupDefaults: defaults,
            initialState: .watchDriver
        )
        ownership.update(state: .recovering(reason: .timeoutWaitingForConfirmation,
                                              lastKnownOwner: .watch))
        XCTAssertEqual(mock.disconnectCallCount, 0,
                       ".recovering with lastKnownOwner=.watch keeps watch as driver")
    }

    // MARK: - Helpers

    private func makeTestPayload(validUntil: Date = Date(timeIntervalSinceNow: 60)) -> OmniBLEHandoffPayload {
        return OmniBLEHandoffPayload(
            podSerial: "TEST_POD_\(UUID().uuidString.prefix(8))",
            serializedPodState: Data("dummy".utf8),
            lastBolusSequence: nil,
            lastBasalScheduleId: nil,
            validUntil: validUntil
        )
    }
}
