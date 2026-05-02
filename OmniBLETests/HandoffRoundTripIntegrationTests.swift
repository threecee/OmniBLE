//
//  HandoffRoundTripIntegrationTests.swift
//  OmniBLETests
//
//  Approach A from docs/research/2026-04-25-pod-hardware-emulation.md:
//  Chained HandoffStateMachine + OmniBLEOwnership round-trip integration test
//  that drives phone→watch→phone handoff and asserts the exact call sequence on
//  both sides' mock pump managers, including LTK payload restoration.
//
//  This is the strongest hardware-pending verification available for B.2.e:
//  it wires the two systems together exactly as HandoffOrchestrator would, but
//  routes WCSession messages through direct method calls instead of real radio.
//

import XCTest
@testable import OmniBLE

// MARK: - Test class

@MainActor
final class HandoffRoundTripIntegrationTests: XCTestCase {

    // Phone side
    var phoneStateMachine: HandoffStateMachine!
    var phoneOwnership: OmniBLEOwnership!
    var phoneMockPump: MockOmniBLEPumpManager!

    // Watch side
    var watchStateMachine: HandoffStateMachine!
    var watchOwnership: OmniBLEOwnership!
    var watchMockPump: MockOmniBLEPumpManager!

    // Per-side App Group UserDefaults (separate suites — two devices in real life)
    var phoneDefaults: UserDefaults!
    var watchDefaults: UserDefaults!

    private var phoneSuiteName: String!
    private var watchSuiteName: String!

    // MARK: setUp / tearDown

    override func setUp() async throws {
        try await super.setUp()

        // Separate UserDefaults suites per test run so state never leaks.
        phoneSuiteName = "HandoffRoundTrip-Phone-\(UUID().uuidString)"
        watchSuiteName = "HandoffRoundTrip-Watch-\(UUID().uuidString)"
        phoneDefaults = UserDefaults(suiteName: phoneSuiteName)!
        watchDefaults = UserDefaults(suiteName: watchSuiteName)!
        phoneDefaults.removePersistentDomain(forName: phoneSuiteName)
        watchDefaults.removePersistentDomain(forName: watchSuiteName)

        // Phone starts as the driver (phoneDriver is the default initial state).
        phoneMockPump = MockOmniBLEPumpManager()
        phoneStateMachine = HandoffStateMachine(initialState: .phoneDriver, role: .phone,
                                                appGroupDefaults: phoneDefaults)
        phoneOwnership = OmniBLEOwnership(
            role: .phone,
            pumpManager: phoneMockPump,
            appGroupDefaults: phoneDefaults,
            initialState: .phoneDriver
        )

        // Watch starts as non-driver (also phoneDriver initial state — watch hasn't
        // been handed control yet).
        watchMockPump = MockOmniBLEPumpManager()
        watchStateMachine = HandoffStateMachine(initialState: .phoneDriver, role: .watch,
                                                appGroupDefaults: watchDefaults)
        watchOwnership = OmniBLEOwnership(
            role: .watch,
            pumpManager: watchMockPump,
            appGroupDefaults: watchDefaults,
            initialState: .phoneDriver
        )
    }

    override func tearDown() async throws {
        phoneDefaults.removePersistentDomain(forName: phoneSuiteName)
        watchDefaults.removePersistentDomain(forName: watchSuiteName)
        try await super.tearDown()
    }

    // MARK: - Helper: make a real PodState (matches PodState init used in B.2.e Phase 4 tests)

    private func makeRealPodState(bleIdentifier: String = "POD_TEST_42") -> PodState {
        PodState(
            address: 0x1234,
            ltk: Data(repeating: 0xAB, count: 16),
            firmwareVersion: "1.0",
            bleFirmwareVersion: "1.0",
            lotNo: UInt32(1),
            lotSeq: UInt32(1),
            productId: UInt8(0),
            bleIdentifier: bleIdentifier,
            insulinType: .humalog
        )
    }

    // MARK: - Helper: drive notifyUI effects into an ownership instance

    /// Mimics what HandoffOrchestrator.execute does: for each .notifyUI effect,
    /// call ownership.update(state:). Other effects (sendModeSwitch, scheduleTimeout,
    /// etc.) are observable in the returned array; the test code routes them.
    private func driveOwnership(_ ownership: OmniBLEOwnership,
                                 effects: [HandoffSideEffect]) {
        for effect in effects {
            if case .notifyUI(let state) = effect {
                ownership.update(state: state)
            }
        }
    }

    // MARK: - Helper: extract the first sendModeSwitch from an effects array

    private func extractModeSwitch(from effects: [HandoffSideEffect]) -> PhoneWatchModeSwitch? {
        for effect in effects {
            if case .sendModeSwitch(let ms) = effect { return ms }
        }
        return nil
    }

    // MARK: - Primary test: full phone→watch→phone round-trip

    /// Drives a complete phone→watch→phone handoff and asserts:
    ///  - Both state machines end in the correct terminal state
    ///  - Phone mock call log: [.disconnectFromActivePod, .connectToActivePod]
    ///  - Watch mock call log: [.restorePodState(POD_TEST_42), .connectToActivePod, .disconnectFromActivePod]
    ///  - LTK bytes survive the encode→cache→decode→restore round-trip
    func testFullPhoneToWatchToPhoneRoundTrip() throws {
        let bleId = "POD_TEST_42"
        let initialPodState = makeRealPodState(bleIdentifier: bleId)
        let originalLTK = initialPodState.ltk

        // Build the real OmniBLEHandoffPayload that the phone's orchestrator
        // would normally attach before sending the WCSession pairingHandoff.
        let payload = try OmniBLEHandoffPayload(
            podState: initialPodState,
            validUntil: Date(timeIntervalSinceNow: 300)
        )

        // ===== PHASE A: Phone initiates handoff to watch =====

        // Step 1: Phone user clicks handoff.
        let phoneEffectsA = phoneStateMachine.handle(.userRequestedHandoff(target: .watch))

        // Drive ownership first (notifyUI(.handoffPending) keeps phone as owner
        // — no BLE action here).
        driveOwnership(phoneOwnership, effects: phoneEffectsA)

        // Phone is now in handoffPending — hasn't released BLE yet.
        guard case .handoffPending(direction: .phoneToWatch, _, _) = phoneStateMachine.state else {
            return XCTFail("Phone should be handoffPending(phoneToWatch); got \(phoneStateMachine.state)")
        }
        XCTAssertTrue(phoneMockPump.callLog.isEmpty,
                      "Phone hasn't released BLE during pending")

        // Step 2: Extract the modeSwitch from phone's effects and deliver to watch.
        // (The pairingHandoff payload is empty from the state machine; we inject the
        // real payload directly via cachePayload, simulating what the orchestrator
        // does after filling the payload before WCSession transmission.)
        guard let msSentByPhone = extractModeSwitch(from: phoneEffectsA) else {
            return XCTFail("Phone should have emitted a sendModeSwitch")
        }

        // Deliver the real payload to the watch side.
        watchOwnership.cachePayload(payload)

        // Deliver the modeSwitch to the watch state machine.
        // The watch is in .phoneDriver + receives targetMode:.watchDriver → self-completes.
        let watchEffectsFromStep2 = watchStateMachine.handle(.incomingModeSwitch(msSentByPhone))

        // Drive watch ownership (last notifyUI will be .watchDriver → acquireBLE fires).
        driveOwnership(watchOwnership, effects: watchEffectsFromStep2)

        // Step 3: Assert watch side.
        XCTAssertEqual(watchStateMachine.state, .watchDriver,
                       "Watch self-completed to .watchDriver (Phase 1 fix)")
        XCTAssertTrue(watchOwnership.iAmDriver, "watchOwnership should report iAmDriver=true")

        // Watch mock should have: [.restorePodState(bleId), .connectToActivePod]
        XCTAssertEqual(watchMockPump.callLog, [
            .restorePodState(podSerial: bleId),
            .connectToActivePod
        ], "Watch should restore pod state then connect")

        // LTK bytes survived encode→PropertyList→decode→restore
        XCTAssertEqual(watchMockPump.restoredPodStates.first?.ltk, originalLTK,
                       "LTK bytes should survive the payload encode/decode round-trip")
        XCTAssertEqual(watchMockPump.restoredPodStates.first?.bleIdentifier, bleId,
                       "bleIdentifier (pod serial proxy) should match after round-trip")

        // Step 4: Deliver watch's confirm modeSwitch back to phone.
        guard let msConfirmFromWatch = extractModeSwitch(from: watchEffectsFromStep2) else {
            return XCTFail("Watch should have emitted a sendModeSwitch (confirm)")
        }
        let phoneEffectsAfterConfirm = phoneStateMachine.handle(.incomingModeSwitch(msConfirmFromWatch))
        driveOwnership(phoneOwnership, effects: phoneEffectsAfterConfirm)

        // Step 5: Assert phone side after confirm.
        XCTAssertEqual(phoneStateMachine.state, .watchDriver,
                       "Phone completes to .watchDriver on receiving watch's confirm")
        XCTAssertFalse(phoneOwnership.iAmDriver, "phoneOwnership: iAmDriver=false now")

        // Phone mock should have: [.disconnectFromActivePod] at this point.
        XCTAssertEqual(phoneMockPump.callLog, [.disconnectFromActivePod],
                       "Phone should have disconnected when it left driver role")

        // ===== PHASE B: Watch hands back to phone =====

        // Step 6: Watch user clicks handoff back to phone.
        let watchEffectsB = watchStateMachine.handle(.userRequestedHandoff(target: .phone))
        driveOwnership(watchOwnership, effects: watchEffectsB)

        guard case .handoffPending(direction: .watchToPhone, _, _) = watchStateMachine.state else {
            return XCTFail("Watch should be handoffPending(watchToPhone); got \(watchStateMachine.state)")
        }
        // Watch hasn't released BLE yet (still owner during pending).
        XCTAssertEqual(watchMockPump.callLog, [
            .restorePodState(podSerial: bleId),
            .connectToActivePod
        ], "Watch callLog unchanged during pending")

        // Step 7: Deliver watch's modeSwitch to phone.
        guard let msSentByWatch = extractModeSwitch(from: watchEffectsB) else {
            return XCTFail("Watch should have emitted a sendModeSwitch for reverse handoff")
        }

        // Phone is in .watchDriver + receives targetMode:.phoneDriver → self-completes.
        let phoneEffectsFromStep7 = phoneStateMachine.handle(.incomingModeSwitch(msSentByWatch))
        driveOwnership(phoneOwnership, effects: phoneEffectsFromStep7)

        // Assert phone side after reverse self-completion.
        XCTAssertEqual(phoneStateMachine.state, .phoneDriver,
                       "Phone self-completes to .phoneDriver on reverse handoff (Phase 1 fix)")
        XCTAssertTrue(phoneOwnership.iAmDriver, "phoneOwnership: iAmDriver=true again")

        // Phone mock now: [.disconnectFromActivePod, .connectToActivePod]
        XCTAssertEqual(phoneMockPump.callLog, [
            .disconnectFromActivePod,
            .connectToActivePod
        ], "Phone call log: disconnect (phase A) then connect (phase B reverse)")

        // Step 8: Deliver phone's confirm back to watch.
        guard let msConfirmFromPhone = extractModeSwitch(from: phoneEffectsFromStep7) else {
            return XCTFail("Phone should emit a sendModeSwitch (confirm) in reverse handoff")
        }
        let watchEffectsAfterConfirm = watchStateMachine.handle(.incomingModeSwitch(msConfirmFromPhone))
        driveOwnership(watchOwnership, effects: watchEffectsAfterConfirm)

        // ===== FINAL ASSERTIONS =====

        XCTAssertEqual(watchStateMachine.state, .phoneDriver,
                       "Watch state machine ends in .phoneDriver")
        XCTAssertFalse(watchOwnership.iAmDriver, "watchOwnership: iAmDriver=false")

        // Final call log assertions.
        XCTAssertEqual(phoneMockPump.callLog, [
            .disconnectFromActivePod,
            .connectToActivePod
        ], "Phone total: disconnect (A) + connect (B)")

        XCTAssertEqual(watchMockPump.callLog, [
            .restorePodState(podSerial: bleId),
            .connectToActivePod,
            .disconnectFromActivePod
        ], "Watch total: restore+connect (A) + disconnect (B)")
    }

    // MARK: - Supporting test 1: reverse handoff without cached payload

    /// Watch becomes driver without a cached payload, hands back to phone;
    /// phone has its own in-memory PodState and doesn't need the payload.
    /// Phone should call .connectToActivePod (no .restorePodState) on reverse handoff.
    func testReverseHandoffWithoutCachedPayloadStillConnects() throws {
        // Start: watch is already driver (simulates a scenario where the watch
        // received driver at launch from a persisted state, not via a live handoff).
        let wsm = HandoffStateMachine(initialState: .watchDriver, role: .watch,
                                      appGroupDefaults: watchDefaults)
        let psm = HandoffStateMachine(initialState: .watchDriver, role: .phone,
                                      appGroupDefaults: phoneDefaults)

        let watchOwnershipB = OmniBLEOwnership(
            role: .watch, pumpManager: watchMockPump,
            appGroupDefaults: watchDefaults, initialState: .watchDriver
        )
        let phoneOwnershipB = OmniBLEOwnership(
            role: .phone, pumpManager: phoneMockPump,
            appGroupDefaults: phoneDefaults, initialState: .watchDriver
        )

        // Watch initiates handoff to phone.
        let watchEffects = wsm.handle(.userRequestedHandoff(target: .phone))
        driveOwnership(watchOwnershipB, effects: watchEffects)

        guard let msSentByWatch = extractModeSwitch(from: watchEffects) else {
            return XCTFail("Watch should emit a sendModeSwitch")
        }

        // Phone receives it — self-completes to phoneDriver (no cached payload on phone side).
        let phoneEffects = psm.handle(.incomingModeSwitch(msSentByWatch))
        driveOwnership(phoneOwnershipB, effects: phoneEffects)

        XCTAssertEqual(psm.state, .phoneDriver, "Phone self-completes to phoneDriver")
        XCTAssertTrue(phoneOwnershipB.iAmDriver)

        // Phone had NO cached payload → no restorePodState call, but connectToActivePod fires.
        XCTAssertEqual(phoneMockPump.callLog, [.connectToActivePod],
                       "Phone connects even without a cached payload (uses in-memory state)")
        XCTAssertTrue(phoneMockPump.restoredPodStates.isEmpty,
                      "No restorePodState when no cached payload is present")

        // Deliver confirm back to watch.
        guard let msConfirm = extractModeSwitch(from: phoneEffects) else {
            return XCTFail("Phone should emit confirm modeSwitch")
        }
        let watchEffectsAfterConfirm = wsm.handle(.incomingModeSwitch(msConfirm))
        driveOwnership(watchOwnershipB, effects: watchEffectsAfterConfirm)

        XCTAssertEqual(wsm.state, .phoneDriver, "Watch ends in .phoneDriver")
        XCTAssertEqual(watchMockPump.callLog, [.disconnectFromActivePod],
                       "Watch disconnects when it loses driver role")
    }

    // MARK: - Supporting test 2: stale cached payload is skipped at acquire

    /// Watch ownership has an expired cached payload; on transition to .watchDriver,
    /// restorePodState is NOT called but connectToActivePod still is
    /// (per OmniBLEOwnership Phase 4 design — expired payload is ignored).
    func testStaleCachedPayloadIsSkippedAtAcquire() throws {
        let bleId = "POD_STALE_99"
        let stalePodState = makeRealPodState(bleIdentifier: bleId)

        // Build a payload that expired 60 seconds ago.
        let expiredPayload = try OmniBLEHandoffPayload(
            podState: stalePodState,
            validUntil: Date(timeIntervalSinceNow: -60)
        )
        watchOwnership.cachePayload(expiredPayload)

        // Sanity check: payload is in the cache but expired.
        XCTAssertNotNil(watchOwnership.cachedPayload)
        XCTAssertFalse(watchOwnership.cachedPayload!.isValid(now: Date()),
                       "Payload should be expired")

        // Phone initiates handoff.
        let phoneEffectsA = phoneStateMachine.handle(.userRequestedHandoff(target: .watch))
        driveOwnership(phoneOwnership, effects: phoneEffectsA)

        guard let ms = extractModeSwitch(from: phoneEffectsA) else {
            return XCTFail("Phone should emit a sendModeSwitch")
        }

        // Watch receives it and transitions to .watchDriver.
        let watchEffects = watchStateMachine.handle(.incomingModeSwitch(ms))
        driveOwnership(watchOwnership, effects: watchEffects)

        XCTAssertEqual(watchStateMachine.state, .watchDriver)
        XCTAssertTrue(watchOwnership.iAmDriver)

        // restorePodState must NOT have been called (expired payload skipped).
        XCTAssertTrue(watchMockPump.restoredPodStates.isEmpty,
                      "Expired payload must NOT trigger restorePodState")
        XCTAssertEqual(watchMockPump.connectCallCount, 1,
                       "connectToActivePod must still be called even when payload is expired")

        // Call log: only .connectToActivePod, no .restorePodState.
        XCTAssertEqual(watchMockPump.callLog, [.connectToActivePod],
                       "Watch callLog: connect only (no restore) when payload is expired")
    }
}
