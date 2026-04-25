//
//  PodBasalTests.swift
//  OmniBLETests
//
//  Basal-operation integration tests against the Pi sim. Each test pairs
//  a fresh pod (full activation flow), then exercises a basal/temp-basal
//  operation and asserts the expected pod outcome.
//
//  API surface (from OmniBLEPumpManager.swift):
//    enactTempBasal(unitsPerHour:for:completion:)   — duration=0 cancels temp basal
//    setBasalSchedule(_:completion:)
//
//  All tests are numbered in continuation of the Phase 6 series (9 bolus tests).
//  Phase 7 basal tests start at 10.
//

import XCTest
import CoreBluetoothMock
import LoopKit
@testable import OmniBLE

final class PodBasalTests: PodSimulatorTestCase {

    // MARK: - 10. testEnactTempBasal

    /// Pair a fresh pod, enact a 30-minute temp basal at 1.5 U/hr, immediately
    /// query status, and assert the deliveryStatus reflects an active temp basal.
    func testEnactTempBasal() throws {
        let manager = try pairFreshPod()

        // Enact a 1.5 U/hr temp basal for 30 minutes.
        let tbExp = expectation(description: "enactTempBasal")
        var tbError: PumpManagerError?

        manager.enactTempBasal(unitsPerHour: 1.5, for: .minutes(30)) { error in
            tbError = error
            tbExp.fulfill()
        }
        wait(for: [tbExp], timeout: 15.0)

        if let error = tbError {
            XCTFail("enactTempBasal failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Query status immediately — temp basal window should still be open.
        let statusExp = expectation(description: "getPodStatus-after-tempBasal")
        var statusResult: PumpManagerResult<StatusResponse>?

        manager.getPodStatus { result in
            statusResult = result
            statusExp.fulfill()
        }
        wait(for: [statusExp], timeout: 10.0)

        switch statusResult {
        case .success(let status):
            let tempBasalActive = [
                DeliveryStatus.tempBasalRunning,
                DeliveryStatus.bolusAndTempBasal,
                DeliveryStatus.extendedBolusAndTempBasal,
            ].contains(status.deliveryStatus)
            XCTAssertTrue(
                tempBasalActive,
                "expected a temp-basal-active delivery status after enacting 1.5 U/hr, got \(status.deliveryStatus)"
            )
        case .failure(let error):
            XCTFail("getPodStatus failed: \(error)\nstderr: \(self.bridge.stderrTail())")
        case nil:
            XCTFail("getPodStatus did not call completion")
        }
    }

    // MARK: - 11. testCancelTempBasal

    /// Pair, enact a 30-minute temp basal, cancel it (duration=0), assert
    /// the pod returns to scheduled basal delivery.
    ///
    /// The OmniBLE convention for cancelling a temp basal is to call
    /// enactTempBasal with duration=0 — the pump manager treats this as a
    /// "resume scheduled basal" command which cancels any active temp basal.
    func testCancelTempBasal() throws {
        let manager = try pairFreshPod()

        // Enact a temp basal first.
        let tbExp = expectation(description: "enactTempBasal")
        var tbError: PumpManagerError?

        manager.enactTempBasal(unitsPerHour: 1.5, for: .minutes(30)) { error in
            tbError = error
            tbExp.fulfill()
        }
        wait(for: [tbExp], timeout: 15.0)

        if let error = tbError {
            XCTFail("enactTempBasal failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Confirm temp basal is running before cancelling.
        let preStatusExp = expectation(description: "pre-cancel status")
        var preStatus: StatusResponse?
        manager.getPodStatus { result in
            if case .success(let s) = result { preStatus = s }
            preStatusExp.fulfill()
        }
        wait(for: [preStatusExp], timeout: 10.0)

        guard let pre = preStatus else {
            XCTFail("pre-cancel status was nil")
            return
        }

        guard [DeliveryStatus.tempBasalRunning, .bolusAndTempBasal, .extendedBolusAndTempBasal].contains(pre.deliveryStatus) else {
            XCTFail("expected temp basal running before cancel, got \(pre.deliveryStatus)")
            return
        }

        // Cancel the temp basal by enacting with duration = 0.
        let cancelExp = expectation(description: "cancelTempBasal via duration=0")
        var cancelError: PumpManagerError?

        manager.enactTempBasal(unitsPerHour: 0.0, for: 0.0) { error in
            cancelError = error
            cancelExp.fulfill()
        }
        wait(for: [cancelExp], timeout: 15.0)

        if let error = cancelError {
            XCTFail("cancel temp basal failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Query status — should be back to scheduled basal.
        let postStatusExp = expectation(description: "post-cancel status")
        var postStatus: StatusResponse?
        manager.getPodStatus { result in
            if case .success(let s) = result { postStatus = s }
            else if case .failure(let e) = result {
                XCTFail("post-cancel getPodStatus failed: \(e)\nstderr: self.bridge.stderrTail()")
            }
            postStatusExp.fulfill()
        }
        wait(for: [postStatusExp], timeout: 10.0)

        guard let post = postStatus else {
            XCTFail("post-cancel status was nil")
            return
        }

        let tempBasalStillActive = [
            DeliveryStatus.tempBasalRunning,
            DeliveryStatus.bolusAndTempBasal,
            DeliveryStatus.extendedBolusAndTempBasal,
        ].contains(post.deliveryStatus)

        XCTAssertFalse(
            tempBasalStillActive,
            "temp basal should be cancelled, expected scheduledBasal or suspended, got \(post.deliveryStatus)"
        )
    }

    // MARK: - 12. testSetBasalSchedule

    /// Pair a fresh pod, set a new basal schedule (0.7 U/hr for 24h), assert
    /// the call completes without error, and query status to confirm pod is
    /// still delivering (not faulted / errored).
    ///
    /// Note: the Go sim does not expose the programmed basal rate directly via
    /// GetStatus; the test asserts success of the command and that subsequent
    /// status queries succeed, confirming the pod remained operational after
    /// the schedule change.
    func testSetBasalSchedule() throws {
        let manager = try pairFreshPod()

        // Build a simple flat basal schedule: 0.7 U/hr for all 24 hours.
        let newSchedule = BasalSchedule(entries: [
            BasalScheduleEntry(rate: 0.7, startTime: 0)
        ])

        let schedExp = expectation(description: "setBasalSchedule")
        var schedError: Error?

        manager.setBasalSchedule(newSchedule) { error in
            schedError = error
            schedExp.fulfill()
        }
        wait(for: [schedExp], timeout: 15.0)

        if let error = schedError {
            XCTFail("setBasalSchedule failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Verify the manager's stored schedule was updated.
        XCTAssertEqual(
            manager.state.basalSchedule.entries.first?.rate, 0.7,
            "stored basalSchedule should reflect the new 0.7 U/hr rate"
        )

        // Query status — pod should still be running after basal schedule update.
        let statusExp = expectation(description: "getPodStatus-after-schedule-set")
        var statusResult: PumpManagerResult<StatusResponse>?

        manager.getPodStatus { result in
            statusResult = result
            statusExp.fulfill()
        }
        wait(for: [statusExp], timeout: 10.0)

        switch statusResult {
        case .success(let status):
            // Pod should not be faulted and should be delivering basally.
            XCTAssertFalse(
                status.deliveryStatus == .suspended,
                "pod should not be suspended after setBasalSchedule, got \(status.deliveryStatus)"
            )
        case .failure(let error):
            XCTFail("getPodStatus failed after setBasalSchedule: \(error)\nstderr: \(self.bridge.stderrTail())")
        case nil:
            XCTFail("getPodStatus did not call completion")
        }
    }
}
