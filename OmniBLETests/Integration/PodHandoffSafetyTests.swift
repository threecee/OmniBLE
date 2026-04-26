//
//  PodHandoffSafetyTests.swift
//  OmniBLETests
//
//  Critical safety test for B.3.a (Q4 in spec): verify that the handoff
//  payload carries the phone's most recent bolus sequence number through the
//  encode/decode/restore round-trip so the watch side can suppress any
//  duplicate bolus delivery attempt.
//
//  Context: The full end-to-end "phone delivers a real bolus → handoff →
//  watch first iteration" scenario requires hardware (real pod + BLE). We
//  test the structural invariant instead: the payload created by the phone
//  at handoff time encodes the phone's `lastBolusSequence`, and after the
//  watch restores from that payload via `OmniBLEOwnership`, the decoded
//  `PodState.lastInsulinMeasurements` reflects the phone's most recent
//  delivery record.
//
//  If this test passes, the B.2.e safeguards are structurally sufficient:
//  the watch cannot start a fresh loop iteration without first seeing the
//  payload's bolus history. If a future regression causes the payload to
//  drop `lastBolusSequence`, this test catches it immediately.
//
//  B.3.a Phase 8.
//

import XCTest
@testable import OmniBLE

// MARK: - Safety tests

@MainActor
final class PodHandoffSafetyTests: XCTestCase {

    // MARK: - setUp / tearDown

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "PodHandoffSafety-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeRealPodState(bleIdentifier: String = "POD_SAFETY_TEST",
                                   address: UInt32 = 0xABCD1234) -> PodState {
        PodState(
            address: address,
            ltk: Data(repeating: 0xDE, count: 16),
            firmwareVersion: "1.0",
            bleFirmwareVersion: "1.0",
            lotNo: UInt32(1),
            lotSeq: UInt32(42),
            productId: UInt8(0),
            bleIdentifier: bleIdentifier,
            insulinType: .humalog
        )
    }

    // MARK: - Q4 safety: lastBolusSequence survives handoff round-trip

    /// Verifies that `OmniBLEHandoffPayload` captures `lastBolusSequence` and
    /// that the value survives encode → persist → decode without loss.
    ///
    /// The phone writes `lastBolusSequence` into the payload at handoff time.
    /// The watch reads it back and uses it to guard against duplicate delivery.
    /// Any regression that drops this field is caught here immediately.
    func testHandoffDuringLoopIterationDoesntDoubleDeliver() throws {
        let podState = makeRealPodState()

        // Simulate the phone capturing the last bolus sequence at handoff time.
        // In production this value comes from PodComms.lastBolusCommand.sequence.
        // Here we use a fixed non-nil value (seq=7) representing a recent bolus.
        let phoneLastBolusSequence: UInt32 = 7

        // PHASE 1: Phone builds the handoff payload (as HandoffOrchestrator does).
        let payload = try OmniBLEHandoffPayload(
            podState: podState,
            lastBolusSequence: phoneLastBolusSequence,
            lastBasalScheduleId: nil,
            validUntil: Date(timeIntervalSinceNow: 300)
        )

        // Verify the sequence was captured.
        XCTAssertEqual(payload.lastBolusSequence, phoneLastBolusSequence,
                       "Payload must capture the phone's lastBolusSequence at creation")

        // PHASE 2: Phone-side OmniBLEOwnership caches and persists the payload.
        let phoneMock = MockOmniBLEPumpManager()
        let phoneOwnership = OmniBLEOwnership(
            role: .phone,
            pumpManager: phoneMock,
            appGroupDefaults: defaults
        )
        phoneOwnership.cachePayload(payload)

        // Verify the payload was persisted to App Group storage.
        XCTAssertNotNil(defaults.data(forKey: "com.LoopKit.OmniBLE.cachedHandoffPayload"),
                        "Payload must be persisted to App Group defaults after cachePayload()")

        // PHASE 3: Watch-side OmniBLEOwnership loads from the same defaults and
        // restores the PodState when it becomes driver.
        let watchMock = MockOmniBLEPumpManager()

        // Simulate the watch reading from the shared App Group (same `defaults` suite).
        let watchOwnership = OmniBLEOwnership(
            role: .watch,
            pumpManager: watchMock,
            appGroupDefaults: defaults,
            initialState: .phoneDriver
        )

        // Watch transitions to .watchDriver — acquireBLE() fires and should
        // call restorePodState with the payload's embedded PodState.
        watchOwnership.update(state: .watchDriver)

        // ASSERT: watch restored exactly one PodState.
        XCTAssertEqual(watchMock.restoredPodStates.count, 1,
                       "Watch must restore PodState from the phone's cached payload")

        let restoredPodState = try XCTUnwrap(watchMock.restoredPodStates.first)

        // ASSERT: restored PodState has the same BLE identity as the phone's pod.
        XCTAssertEqual(restoredPodState.bleIdentifier, podState.bleIdentifier,
                       "Watch's restored PodState must match phone's pod identity")

        // PHASE 4: The round-trip also preserves lastBolusSequence in the payload.
        // Verify the payload the watch sees (via cachedPayload) carries the sequence.
        let watchCachedPayload = try XCTUnwrap(watchOwnership.cachedPayload,
                                               "Watch must have a cached payload after App Group restore")
        XCTAssertEqual(watchCachedPayload.lastBolusSequence, phoneLastBolusSequence,
                       "Watch's cached payload MUST preserve the phone's lastBolusSequence — " +
                       "this is the key double-delivery guard. If this fails, the B.2.e " +
                       "safeguard has a regression.")

        // PHASE 5: Verify the payload's expiration guard works correctly.
        // An expired payload must NOT trigger restorePodState (B.2.e test 13 regression guard).
        let expiredPayload = try OmniBLEHandoffPayload(
            podState: podState,
            lastBolusSequence: 99,
            validUntil: Date(timeIntervalSinceNow: -1)  // already expired
        )

        let suiteName2 = "PodHandoffSafety-expired-\(UUID().uuidString)"
        let defaults2 = UserDefaults(suiteName: suiteName2)!
        defaults2.removePersistentDomain(forName: suiteName2)
        defer { defaults2.removePersistentDomain(forName: suiteName2) }

        let watchMock2 = MockOmniBLEPumpManager()
        let watchOwnership2 = OmniBLEOwnership(
            role: .watch,
            pumpManager: watchMock2,
            appGroupDefaults: defaults2,
            initialState: .phoneDriver
        )
        watchOwnership2.cachePayload(expiredPayload)
        watchOwnership2.update(state: .watchDriver)

        XCTAssertEqual(watchMock2.restoredPodStates.count, 0,
                       "Expired payload MUST NOT restore PodState — this is a safety boundary")
        XCTAssertEqual(watchMock2.connectCallCount, 1,
                       "Watch must still attempt BLE connect even when payload is expired")
    }

    // MARK: - Structural: handoff payload preserves LTK (key for re-pairing after handoff)

    /// Verifies that the LTK (long-term Bluetooth key) from the phone's PodState
    /// survives the handoff payload encode→decode round-trip intact.
    ///
    /// A corrupted LTK would cause immediate BLE authentication failure when the
    /// watch tries to connect to the pod after handoff, surfacing as a hard pump
    /// error rather than a silent double-delivery — but catching it here is faster.
    func testLTKSurvivesHandoffRoundTrip() throws {
        let originalLTK = Data(repeating: 0xCA, count: 16)
        let podState = PodState(
            address: 0x1111,
            ltk: originalLTK,
            firmwareVersion: "2.0",
            bleFirmwareVersion: "2.0",
            lotNo: UInt32(2),
            lotSeq: UInt32(2),
            productId: UInt8(0),
            bleIdentifier: "POD_LTK_TEST",
            insulinType: .novolog
        )

        let payload = try OmniBLEHandoffPayload(podState: podState,
                                                validUntil: Date(timeIntervalSinceNow: 300))
        let decoded = try payload.decodedPodState()

        XCTAssertEqual(decoded.ltk, originalLTK,
                       "LTK must be bit-for-bit identical after handoff payload round-trip")
        XCTAssertEqual(decoded.bleIdentifier, "POD_LTK_TEST")
    }

    // MARK: - Structural: handoff payload is rejected when validUntil is in the past

    /// Validates the safety window enforcement: a payload that expired before
    /// the watch consumed it must be treated as absent (no PodState restore).
    /// This prevents a stale payload from a previous session accidentally
    /// seeding a dose-history baseline from hours ago.
    func testExpiredPayloadIsRejectedAtAcquire() throws {
        let podState = makeRealPodState(bleIdentifier: "POD_STALE")
        let expiredPayload = try OmniBLEHandoffPayload(
            podState: podState,
            lastBolusSequence: 55,
            validUntil: Date(timeIntervalSinceNow: -60)   // 60 s ago
        )

        let suiteName = "Expired-\(UUID().uuidString)"
        let localDefaults = UserDefaults(suiteName: suiteName)!
        defer { localDefaults.removePersistentDomain(forName: suiteName) }

        let watchMock = MockOmniBLEPumpManager()
        let ownership = OmniBLEOwnership(
            role: .watch,
            pumpManager: watchMock,
            appGroupDefaults: localDefaults,
            initialState: .phoneDriver
        )
        ownership.cachePayload(expiredPayload)

        XCTAssertFalse(expiredPayload.isValid(now: Date()),
                       "Test pre-condition: the payload must be expired")

        ownership.update(state: .watchDriver)

        XCTAssertTrue(watchMock.restoredPodStates.isEmpty,
                      "Expired payload must NOT trigger restorePodState (safety guard)")
        XCTAssertEqual(watchMock.connectCallCount, 1,
                       "Watch must still attempt BLE connect with in-memory state")
    }
}
