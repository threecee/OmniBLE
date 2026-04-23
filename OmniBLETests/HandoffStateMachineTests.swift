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

    func testPhoneDriver_incomingModeSwitchToWatchDriver_transitionsViaHandoffPending() {
        // Watch initiated takeover; phone receives mode switch → enters handoffPending.
        let m = machine(role: .phone)
        let id = UUID()
        let ms = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: now,
            requestedBy: .watch, targetMode: .watchDriver, transitionId: id)
        _ = m.handle(.incomingModeSwitch(ms), now: now)
        if case .handoffPending(direction: .phoneToWatch, transitionId: let recordedId, _) = m.state {
            XCTAssertEqual(recordedId, id)
        } else {
            XCTFail("expected handoffPending(phoneToWatch, id=\(id)), got \(m.state)")
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

    func testWatchDriver_incomingModeSwitchToPhoneDriver_transitionsViaHandoffPending() {
        let m = machine(role: .watch, initial: .watchDriver)
        let id = UUID()
        let ms = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: now,
            requestedBy: .phone, targetMode: .phoneDriver, transitionId: id)
        _ = m.handle(.incomingModeSwitch(ms), now: now)
        if case .handoffPending(direction: .watchToPhone, transitionId: let recordedId, _) = m.state {
            XCTAssertEqual(recordedId, id)
        } else {
            XCTFail("expected handoffPending(watchToPhone), got \(m.state)")
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
}
