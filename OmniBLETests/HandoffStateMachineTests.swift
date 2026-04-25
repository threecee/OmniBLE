//
//  HandoffStateMachineTests.swift
//  OmniBLETests
//

import XCTest
@testable import OmniBLE

final class HandoffStateMachineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func machine(role: HandoffRole = .phone,
                         initial: HandoffState = .phoneDriver) -> HandoffStateMachine {
        HandoffStateMachine(initialState: initial, role: role)
    }

    // MARK: - From PhoneDriver

    func testPhoneDriver_userRequestsHandoffToWatch_transitionsToHandoffPendingPhoneToWatch() {
        let m = machine(role: .phone)
        let effects = m.handle(.userRequestedHandoff(target: .watch), now: now)

        if case .handoffPending(direction: .phoneToWatch, _, let deadline) = m.state {
            XCTAssertEqual(deadline, now.addingTimeInterval(30))
        } else {
            XCTFail("expected handoffPending(phoneToWatch), got \(m.state)")
        }
        XCTAssertTrue(effects.contains { if case .stopIssuingPodCommands = $0 { return true }; return false })
        XCTAssertTrue(effects.contains { if case .sendPairingHandoff = $0 { return true }; return false })
        XCTAssertTrue(effects.contains { if case .sendModeSwitch = $0 { return true }; return false })
        XCTAssertTrue(effects.contains { if case .scheduleTimeout = $0 { return true }; return false })
    }

    func testPhoneDriver_policyRequestsHandoffToWatch_transitionsToHandoffPendingPhoneToWatch() {
        let m = machine(role: .phone)
        _ = m.handle(.policyRequestedHandoff(target: .watch), now: now)
        if case .handoffPending(direction: .phoneToWatch, _, _) = m.state {
            // OK
        } else {
            XCTFail("expected handoffPending")
        }
    }

    func testPhoneDriver_userRequestsHandoffToPhone_isNoop() {
        let m = machine(role: .phone)
        let effects = m.handle(.userRequestedHandoff(target: .phone), now: now)
        XCTAssertEqual(m.state, .phoneDriver)
        XCTAssertTrue(effects.isEmpty)
    }

    func testPhoneDriver_shadowRefreshDue_emitsPairingHandoffWithoutChangingState() {
        let m = machine(role: .phone)
        let effects = m.handle(.shadowStateRefreshDue, now: now)
        XCTAssertEqual(m.state, .phoneDriver)
        XCTAssertTrue(effects.contains { if case .sendPairingHandoff = $0 { return true }; return false })
    }

    func testPhoneDriver_incomingModeSwitchToWatchDriver_selfCompletes() {
        // After B.2.e Phase 1: receiver self-completes to .watchDriver in one event
        // (was: stayed in .handoffPending awaiting initiator ack that never came).
        let sm = HandoffStateMachine(initialState: .phoneDriver, role: .watch)
        let tid = UUID()
        let ms = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            requestedBy: .phone,
            targetMode: .watchDriver,
            transitionId: tid
        )
        let effects = sm.handle(.incomingModeSwitch(ms))

        if case .watchDriver = sm.state {} else {
            XCTFail("Expected .watchDriver after self-completion; got \(sm.state)")
        }

        // Confirm modeSwitch went out (from enterPending), and final notifyUI
        // reflects the completed state.
        XCTAssertTrue(effects.contains { if case .sendModeSwitch = $0 { return true }; return false },
                      "Expected sendModeSwitch (confirm) from enterPending")
        if case .notifyUI(let last) = effects.last, case .watchDriver = last {} else {
            XCTFail("Expected last effect to be notifyUI(.watchDriver); got \(String(describing: effects.last))")
        }
    }

    // MARK: - From HandoffPending(phoneToWatch)

    private func phoneInPending(id: UUID) -> HandoffStateMachine {
        machine(role: .phone, initial: .handoffPending(
            direction: .phoneToWatch,
            transitionId: id,
            deadline: now.addingTimeInterval(30)))
    }

    func testHandoffPendingPhoneToWatch_modeSwitchConfirmation_transitionsToWatchDriver() {
        let id = UUID()
        let m = phoneInPending(id: id)
        let confirm = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: now,
            requestedBy: .watch, targetMode: .watchDriver, transitionId: id)
        let effects = m.handle(.incomingModeSwitch(confirm), now: now.addingTimeInterval(2))
        XCTAssertEqual(m.state, .watchDriver)
        XCTAssertTrue(effects.contains { if case .notifyUI = $0 { return true }; return false })
        XCTAssertEqual(m.lastKnownOwner, .watch)
    }

    func testHandoffPendingPhoneToWatch_timeoutReached_transitionsToRecovering() {
        let id = UUID()
        let m = phoneInPending(id: id)
        _ = m.handle(.transitionDeadlineReached(transitionId: id),
                     now: now.addingTimeInterval(31))
        if case .recovering(.timeoutWaitingForConfirmation, lastKnownOwner: .phone) = m.state {
            // OK
        } else {
            XCTFail("expected recovering(timeout, phone), got \(m.state)")
        }
    }

    func testHandoffPendingPhoneToWatch_modeSwitchRejection_transitionsToRecovering() {
        let id = UUID()
        let m = phoneInPending(id: id)
        let reject = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: now,
            requestedBy: .watch, targetMode: .phoneDriver, transitionId: id)
        _ = m.handle(.incomingModeSwitch(reject), now: now.addingTimeInterval(2))
        if case .recovering(.rejectedByCounterpart, lastKnownOwner: .phone) = m.state {
            // OK
        } else {
            XCTFail("expected recovering(rejected, phone), got \(m.state)")
        }
    }

    func testHandoffPendingPhoneToWatch_unrelatedTimeout_isNoop() {
        let id = UUID()
        let unrelated = UUID()
        let m = phoneInPending(id: id)
        let priorState = m.state
        _ = m.handle(.transitionDeadlineReached(transitionId: unrelated),
                     now: now.addingTimeInterval(35))
        XCTAssertEqual(m.state, priorState)
    }

    func testHandoffPendingPhoneToWatch_shadowRefreshDue_isSuppressed() {
        let m = phoneInPending(id: UUID())
        let priorState = m.state
        let effects = m.handle(.shadowStateRefreshDue, now: now)
        XCTAssertEqual(m.state, priorState)
        // Should not emit pairing handoff during transition (avoid stale data).
        XCTAssertFalse(effects.contains { if case .sendPairingHandoff = $0 { return true }; return false })
    }

    // MARK: - From WatchDriver

    func testWatchDriver_userRequestsHandoffToPhone_transitionsToHandoffPendingWatchToPhone() {
        let m = machine(role: .phone, initial: .watchDriver)
        let effects = m.handle(.userRequestedHandoff(target: .phone), now: now)
        if case .handoffPending(direction: .watchToPhone, _, _) = m.state {
            // OK
        } else {
            XCTFail("expected handoffPending(watchToPhone)")
        }
        XCTAssertTrue(effects.contains { if case .sendModeSwitch = $0 { return true }; return false })
    }

    func testWatchDriver_policyRequestsRevertToPhone_transitionsToHandoffPendingWatchToPhone() {
        let m = machine(role: .phone, initial: .watchDriver)
        _ = m.handle(.policyRequestedHandoff(target: .phone), now: now)
        if case .handoffPending(direction: .watchToPhone, _, _) = m.state {
            // OK
        } else {
            XCTFail("expected handoffPending(watchToPhone)")
        }
    }

    func testWatchDriver_userRequestsHandoffToWatch_isNoop() {
        let m = machine(role: .phone, initial: .watchDriver)
        let effects = m.handle(.userRequestedHandoff(target: .watch), now: now)
        XCTAssertEqual(m.state, .watchDriver)
        XCTAssertTrue(effects.isEmpty)
    }

    func testWatchDriver_shadowRefreshDue_emitsPairingHandoff() {
        // From watchDriver, shadow refresh ships state from watch back to phone.
        let m = machine(role: .watch, initial: .watchDriver)
        let effects = m.handle(.shadowStateRefreshDue, now: now)
        XCTAssertEqual(m.state, .watchDriver)
        XCTAssertTrue(effects.contains { if case .sendPairingHandoff = $0 { return true }; return false })
    }

    func testWatchDriver_incomingModeSwitchToPhoneDriver_selfCompletes() {
        let sm = HandoffStateMachine(initialState: .watchDriver, role: .phone)
        let tid = UUID()
        let ms = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            requestedBy: .watch,
            targetMode: .phoneDriver,
            transitionId: tid
        )
        let effects = sm.handle(.incomingModeSwitch(ms))

        if case .phoneDriver = sm.state {} else {
            XCTFail("Expected .phoneDriver after self-completion; got \(sm.state)")
        }
        if case .notifyUI(let last) = effects.last, case .phoneDriver = last {} else {
            XCTFail("Expected last effect to be notifyUI(.phoneDriver); got \(String(describing: effects.last))")
        }
    }

    // MARK: - From HandoffPending(watchToPhone)

    private func watchInPending(id: UUID) -> HandoffStateMachine {
        machine(role: .watch, initial: .handoffPending(
            direction: .watchToPhone,
            transitionId: id,
            deadline: now.addingTimeInterval(30)))
    }

    func testHandoffPendingWatchToPhone_confirmation_transitionsToPhoneDriver() {
        let id = UUID()
        let m = watchInPending(id: id)
        let confirm = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: now,
            requestedBy: .phone, targetMode: .phoneDriver, transitionId: id)
        _ = m.handle(.incomingModeSwitch(confirm), now: now.addingTimeInterval(2))
        XCTAssertEqual(m.state, .phoneDriver)
        XCTAssertEqual(m.lastKnownOwner, .phone)
    }

    func testHandoffPendingWatchToPhone_timeout_recoversToWatchDriver() {
        let id = UUID()
        let m = watchInPending(id: id)
        _ = m.handle(.transitionDeadlineReached(transitionId: id),
                     now: now.addingTimeInterval(31))
        if case .recovering(.timeoutWaitingForConfirmation, lastKnownOwner: .watch) = m.state {
            // OK
        } else {
            XCTFail("expected recovering(timeout, watch), got \(m.state)")
        }
    }

    func testHandoffPendingWatchToPhone_modeSwitchRejection_transitionsToRecovering() {
        let id = UUID()
        let m = watchInPending(id: id)
        let reject = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: now,
            requestedBy: .phone, targetMode: .watchDriver, transitionId: id)
        _ = m.handle(.incomingModeSwitch(reject), now: now.addingTimeInterval(2))
        if case .recovering(.rejectedByCounterpart, lastKnownOwner: .watch) = m.state {
            // OK
        } else {
            XCTFail("expected recovering(rejected, watch), got \(m.state)")
        }
    }

    // MARK: - From Recovering

    func testRecovering_manualDismiss_returnsToLastKnownOwner_phone() {
        let m = machine(role: .phone, initial: .recovering(
            reason: .timeoutWaitingForConfirmation, lastKnownOwner: .phone))
        _ = m.handle(.manualRecoveryDismiss, now: now)
        XCTAssertEqual(m.state, .phoneDriver)
    }

    func testRecovering_manualDismiss_returnsToLastKnownOwner_watch() {
        let m = machine(role: .watch, initial: .recovering(
            reason: .timeoutWaitingForConfirmation, lastKnownOwner: .watch))
        _ = m.handle(.manualRecoveryDismiss, now: now)
        XCTAssertEqual(m.state, .watchDriver)
    }

    func testRecovering_shadowRefresh_isNoop() {
        let m = machine(role: .phone, initial: .recovering(
            reason: .localFailureDuringTransition, lastKnownOwner: .phone))
        let priorState = m.state
        _ = m.handle(.shadowStateRefreshDue, now: now)
        XCTAssertEqual(m.state, priorState)
    }

    func testRecovering_incomingModeSwitch_isNoop() {
        let m = machine(role: .phone, initial: .recovering(
            reason: .timeoutWaitingForConfirmation, lastKnownOwner: .phone))
        let ms = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: now,
            requestedBy: .watch, targetMode: .watchDriver, transitionId: UUID())
        let priorState = m.state
        _ = m.handle(.incomingModeSwitch(ms), now: now)
        XCTAssertEqual(m.state, priorState)
    }

    // MARK: - Idempotency / log

    func testIncomingModeSwitchWithSameTransitionIdRetriedIsIdempotent() {
        let id = UUID()
        let m = phoneInPending(id: id)
        let confirm = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: now,
            requestedBy: .watch, targetMode: .watchDriver, transitionId: id)
        _ = m.handle(.incomingModeSwitch(confirm), now: now.addingTimeInterval(2))
        let stateAfterFirst = m.state

        // Re-deliver same message — should not change state, should not duplicate log entries.
        let logCountBeforeRetry = m.transitionLog.count
        _ = m.handle(.incomingModeSwitch(confirm), now: now.addingTimeInterval(3))
        XCTAssertEqual(m.state, stateAfterFirst)
        XCTAssertEqual(m.transitionLog.count, logCountBeforeRetry)
    }

    func testTransitionLogIsCappedAtTen() {
        let m = machine(role: .phone)
        // Toggle back-and-forth manually-requested handoffs to generate >10 transitions.
        for _ in 0..<8 {
            _ = m.handle(.userRequestedHandoff(target: .watch), now: now)
            // Confirm
            if case .handoffPending(_, let id, _) = m.state {
                let confirm = PhoneWatchModeSwitch(
                    protocolVersion: 1, sentAt: now,
                    requestedBy: .watch, targetMode: .watchDriver, transitionId: id)
                _ = m.handle(.incomingModeSwitch(confirm), now: now)
            }
            _ = m.handle(.userRequestedHandoff(target: .phone), now: now)
            if case .handoffPending(_, let id, _) = m.state {
                let confirm = PhoneWatchModeSwitch(
                    protocolVersion: 1, sentAt: now,
                    requestedBy: .phone, targetMode: .phoneDriver, transitionId: id)
                _ = m.handle(.incomingModeSwitch(confirm), now: now)
            }
        }
        XCTAssertLessThanOrEqual(m.transitionLog.count, 10)
    }

    func testTransitionLogRecordsManualUserTrigger() {
        let m = machine(role: .phone)
        _ = m.handle(.userRequestedHandoff(target: .watch), now: now)
        XCTAssertEqual(m.transitionLog.count, 1)
        XCTAssertEqual(m.transitionLog.first?.from, .phoneDriver)
        XCTAssertEqual(m.transitionLog.first?.to, .handoffPendingPhoneToWatch)
        XCTAssertEqual(m.transitionLog.first?.trigger, .userManual)
    }

    func testTransitionLogRecordsPolicyAutomaticTrigger() {
        let m = machine(role: .phone)
        _ = m.handle(.policyRequestedHandoff(target: .watch), now: now)
        XCTAssertEqual(m.transitionLog.first?.trigger, .policyAutomatic)
    }

    func testTransitionLogRecordsTimeoutTrigger() {
        let id = UUID()
        let m = phoneInPending(id: id)
        _ = m.handle(.transitionDeadlineReached(transitionId: id),
                     now: now.addingTimeInterval(31))
        XCTAssertEqual(m.transitionLog.first?.trigger, .timeout)
        XCTAssertEqual(m.transitionLog.first?.to, .recovering)
    }

    // MARK: - lastKnownOwner stability

    func testLastKnownOwnerStartsPhoneForPhoneDriverInit() {
        let m = machine(initial: .phoneDriver)
        XCTAssertEqual(m.lastKnownOwner, .phone)
    }

    func testLastKnownOwnerStartsWatchForWatchDriverInit() {
        let m = machine(initial: .watchDriver)
        XCTAssertEqual(m.lastKnownOwner, .watch)
    }

    func testLastKnownOwnerPreservesRecoveringInitialOwner() {
        let m = machine(initial: .recovering(
            reason: .timeoutWaitingForConfirmation, lastKnownOwner: .watch))
        XCTAssertEqual(m.lastKnownOwner, .watch)
    }

    // MARK: - B.2.e Phase 1: receiver-side self-completion

    func testInitiatorSideStillCompletesOnReceivedConfirmModeSwitch() {
        // Pre-existing line-62-65 case (initiator side) MUST still work after the
        // receiver-side fix — initiator completes when it receives the receiver's
        // confirm modeSwitch with matching transitionId.
        let initialId = UUID()
        let sm = HandoffStateMachine(
            initialState: .handoffPending(direction: .phoneToWatch,
                                           transitionId: initialId,
                                           deadline: Date().addingTimeInterval(30)),
            role: .phone
        )
        let confirm = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            requestedBy: .watch,
            targetMode: .watchDriver,
            transitionId: initialId
        )
        let effects = sm.handle(.incomingModeSwitch(confirm))
        if case .watchDriver = sm.state {} else {
            XCTFail("Initiator should complete to .watchDriver on confirm; got \(sm.state)")
        }
        XCTAssertEqual(effects.count, 1, "Initiator's completeHandoff emits only notifyUI (no resumeIssuingPodCommands since role=.phone but new owner=.watch)")
    }

    func testReceiverSelfCompletionEffectsOrderHasNotifyUIWatchDriverLast() {
        let sm = HandoffStateMachine(initialState: .phoneDriver, role: .watch)
        let ms = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            requestedBy: .phone,
            targetMode: .watchDriver,
            transitionId: UUID()
        )
        let effects = sm.handle(.incomingModeSwitch(ms))

        // Order matters for OmniBLEOwnership wiring: ownership.update must see
        // the FINAL state after all other effects have been processed. So the
        // last notifyUI must be .watchDriver (not .handoffPending).
        if case .notifyUI(let last) = effects.last, case .watchDriver = last {} else {
            XCTFail("Last effect must be notifyUI(.watchDriver) for ownership.update wiring")
        }
        // resumeIssuingPodCommands SHOULD be present because role=.watch and new owner=.watch
        XCTAssertTrue(effects.contains { if case .resumeIssuingPodCommands = $0 { return true }; return false },
                      "Expected resumeIssuingPodCommands since this side is now the driver")
    }

    func testNonInitiatorSideRejectsModeSwitchWithWrongTargetMode() {
        let sm = HandoffStateMachine(initialState: .phoneDriver, role: .watch)
        let ms = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            requestedBy: .phone,
            targetMode: .phoneDriver,    // wrong target — already in phoneDriver
            transitionId: UUID()
        )
        let effects = sm.handle(.incomingModeSwitch(ms))
        if case .phoneDriver = sm.state {} else {
            XCTFail("State should remain .phoneDriver when target doesn't match")
        }
        XCTAssertTrue(effects.isEmpty, "No effects for no-op handle")
    }

    // MARK: - B.2.e Phase 2 smoke tests

    func testOmniBLEPumpManagerWatchSideDefaultStateHasNilPod() {
        let state = OmniBLEPumpManagerState.watchSideDefault
        XCTAssertNil(state.podState, "Default watch state should have no pod")
        XCTAssertEqual(state.maximumTempBasalRate, 0)
    }

    func testOmniBLEPumpManagerCanInstantiateFromWatchSideDefault() {
        // OmniBLEPumpManager init touches CBCentralManager (requires bluetooth-central
        // entitlement not available in test bundles). Instead verify the state round-trips
        // through rawValue — confirming it is fully serializable for use as a constructor arg.
        let state = OmniBLEPumpManagerState.watchSideDefault
        let raw = state.rawValue
        let restored = OmniBLEPumpManagerState(rawValue: raw)
        XCTAssertNotNil(restored, "watchSideDefault must round-trip through rawValue")
        XCTAssertNil(restored?.podState, "Restored state should still have nil pod")
        XCTAssertEqual(restored?.maximumTempBasalRate, 0)
    }
}
