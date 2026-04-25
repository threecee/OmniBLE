//
//  PodSuspendResumeTests.swift
//  OmniBLETests
//
//  Suspend/resume integration tests against the Pi sim. Each test pairs
//  a fresh pod (full activation flow), then exercises suspend and/or resume
//  and asserts the expected delivery state outcome.
//
//  API surface (from OmniBLEPumpManager.swift):
//    suspendDelivery(completion:)     — untimed suspend with reminder beeps
//    resumeDelivery(completion:)      — resumes with the stored basal schedule
//    setBasalSchedule(_:completion:)  — used in test 16 to set a known schedule
//
//  Tests are numbered starting at 13 (continuing from Phase 7 basal tests).
//

import XCTest
import CoreBluetoothMock
import LoopKit
@testable import OmniBLE

final class PodSuspendResumeTests: PodSimulatorTestCase {

    // MARK: - 13. testSuspendDelivery

    /// Pair a fresh pod, suspend delivery, query status, assert deliveryStatus
    /// indicates the pod is suspended.
    func testSuspendDelivery() throws {
        let manager = try pairFreshPod()

        // Suspend delivery.
        let suspendExp = expectation(description: "suspendDelivery")
        var suspendError: Error?

        manager.suspendDelivery { error in
            suspendError = error
            suspendExp.fulfill()
        }
        wait(for: [suspendExp], timeout: 15.0)

        if let error = suspendError {
            XCTFail("suspendDelivery failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Query status — pod should report suspended.
        let statusExp = expectation(description: "getPodStatus-after-suspend")
        var statusResult: PumpManagerResult<StatusResponse>?

        manager.getPodStatus { result in
            statusResult = result
            statusExp.fulfill()
        }
        wait(for: [statusExp], timeout: 10.0)

        switch statusResult {
        case .success(let status):
            XCTAssertTrue(
                status.deliveryStatus.suspended,
                "deliveryStatus should be suspended after suspendDelivery, got \(status.deliveryStatus)"
            )
        case .failure(let error):
            XCTFail("getPodStatus failed: \(error)\nstderr: \(self.bridge.stderrTail())")
        case nil:
            XCTFail("getPodStatus did not call completion")
        }
    }

    // MARK: - 14. testResumeDelivery

    /// Pair a fresh pod, suspend, then resume delivery. Assert that after
    /// resume, deliveryStatus is no longer suspended.
    func testResumeDelivery() throws {
        let manager = try pairFreshPod()

        // Suspend.
        let suspendExp = expectation(description: "suspendDelivery")
        var suspendError: Error?

        manager.suspendDelivery { error in
            suspendError = error
            suspendExp.fulfill()
        }
        wait(for: [suspendExp], timeout: 15.0)

        if let error = suspendError {
            XCTFail("suspendDelivery failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Resume.
        let resumeExp = expectation(description: "resumeDelivery")
        var resumeError: Error?

        manager.resumeDelivery { error in
            resumeError = error
            resumeExp.fulfill()
        }
        wait(for: [resumeExp], timeout: 15.0)

        if let error = resumeError {
            XCTFail("resumeDelivery failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Query status — should be delivering (not suspended).
        let statusExp = expectation(description: "getPodStatus-after-resume")
        var statusResult: PumpManagerResult<StatusResponse>?

        manager.getPodStatus { result in
            statusResult = result
            statusExp.fulfill()
        }
        wait(for: [statusExp], timeout: 10.0)

        switch statusResult {
        case .success(let status):
            XCTAssertFalse(
                status.deliveryStatus.suspended,
                "deliveryStatus should NOT be suspended after resumeDelivery, got \(status.deliveryStatus)"
            )
        case .failure(let error):
            XCTFail("getPodStatus failed: \(error)\nstderr: \(self.bridge.stderrTail())")
        case nil:
            XCTFail("getPodStatus did not call completion")
        }
    }

    // MARK: - 15. testSuspendThenResumePreservesSchedule

    /// Set a known basal schedule (0.5 U/hr), suspend, resume, assert the
    /// stored basal schedule in the manager is unchanged and the pod is
    /// again delivering (status query succeeds and delivery is not suspended).
    ///
    /// This exercises the resumeDelivery path that re-programs the stored
    /// basalSchedule to the pod after suspend — if the schedule was corrupted
    /// the resume would fail or the pod would fault.
    func testSuspendThenResumePreservesSchedule() throws {
        let manager = try pairFreshPod()

        // Set a known basal schedule.
        let knownSchedule = BasalSchedule(entries: [
            BasalScheduleEntry(rate: 0.5, startTime: 0)
        ])
        let schedExp = expectation(description: "setBasalSchedule")
        var schedError: Error?

        manager.setBasalSchedule(knownSchedule) { error in
            schedError = error
            schedExp.fulfill()
        }
        wait(for: [schedExp], timeout: 15.0)

        if let error = schedError {
            XCTFail("setBasalSchedule failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Suspend.
        let suspendExp = expectation(description: "suspendDelivery")
        var suspendError: Error?

        manager.suspendDelivery { error in
            suspendError = error
            suspendExp.fulfill()
        }
        wait(for: [suspendExp], timeout: 15.0)

        if let error = suspendError {
            XCTFail("suspendDelivery failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Resume.
        let resumeExp = expectation(description: "resumeDelivery")
        var resumeError: Error?

        manager.resumeDelivery { error in
            resumeError = error
            resumeExp.fulfill()
        }
        wait(for: [resumeExp], timeout: 15.0)

        if let error = resumeError {
            XCTFail("resumeDelivery failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Assert the stored schedule rate is still 0.5 U/hr.
        let storedRate = manager.state.basalSchedule.entries.first?.rate ?? 0.0
        XCTAssertEqual(
            storedRate, 0.5,
            "stored basal schedule rate should still be 0.5 U/hr after suspend/resume, got \(storedRate)"
        )

        // Query status — pod should be delivering again (not suspended).
        let statusExp = expectation(description: "getPodStatus-after-resume-preserved-schedule")
        var statusResult: PumpManagerResult<StatusResponse>?

        manager.getPodStatus { result in
            statusResult = result
            statusExp.fulfill()
        }
        wait(for: [statusExp], timeout: 10.0)

        switch statusResult {
        case .success(let status):
            XCTAssertFalse(
                status.deliveryStatus.suspended,
                "deliveryStatus should NOT be suspended after resume, got \(status.deliveryStatus)"
            )
        case .failure(let error):
            XCTFail("getPodStatus failed: \(error)\nstderr: \(self.bridge.stderrTail())")
        case nil:
            XCTFail("getPodStatus did not call completion")
        }
    }
}
