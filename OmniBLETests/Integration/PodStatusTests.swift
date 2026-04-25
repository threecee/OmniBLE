//
//  PodStatusTests.swift
//  OmniBLETests
//
//  Encrypted status-query tests against the Pi sim. Each test pairs a fresh
//  pod (proving the encryption stack works — same as
//  PodActivationTests.testFullActivationFlow), then exercises a status query
//  and asserts the response reflects pod state.
//
//  The Go sim starts a fresh pod with:
//    Reservoir = 150 / 0.05 = 3000 pulses = 150U
//    PodProgress = PodProgressRunningAbove50U (= 8) after full activation
//

import XCTest
import CoreBluetoothMock
import LoopKit
@testable import OmniBLE

final class PodStatusTests: PodSimulatorTestCase {

    // MARK: - 1. testGetPodStatusBasic

    /// Pair a fresh pod, call getPodStatus, assert the StatusResponse is well-formed
    /// and reservoir is above the 50U magic threshold (fresh pod is 150U).
    func testGetPodStatusBasic() throws {
        let manager = try pairFreshPod()

        let exp = expectation(description: "getPodStatus")
        var statusResult: PumpManagerResult<StatusResponse>?

        manager.getPodStatus { result in
            statusResult = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)

        switch statusResult {
        case .success(let status):
            // Fresh pod should be delivering scheduled basal (or basal-related state).
            // The key structural check: deliveryStatus is a recognised case.
            XCTAssertNotNil(status.deliveryStatus.description, "deliveryStatus should be valid")

            // podProgressStatus should be aboveFiftyUnits (8) for a freshly activated pod.
            XCTAssertEqual(
                status.podProgressStatus, PodProgressStatus.aboveFiftyUnits,
                "fresh pod should be aboveFiftyUnits, got \(status.podProgressStatus)"
            )

            // Reservoir: fresh sim starts at 150U. After prime (2.6U) + cannula
            // (0.5U + extra), delivered ≈ 3.1U max, so reservoir should be well above 50U.
            // Pod.reservoirLevelAboveThresholdMagicNumber (51.15) is returned when
            // the pod reports > ~50U — either the real level or the magic number.
            let effectiveReservoir = status.reservoirLevel
            XCTAssertGreaterThan(
                effectiveReservoir, 40.0,
                "reservoir should be substantially above 40U for a fresh pod, got \(effectiveReservoir)"
            )

            // timeActive should be non-negative (pod sim uses real wall clock).
            XCTAssertGreaterThanOrEqual(
                status.timeActive, 0,
                "timeActive should be non-negative"
            )

        case .failure(let error):
            XCTFail("getPodStatus failed: \(error)\nstderr: \(self.bridge.stderrTail())")
        case nil:
            XCTFail("getPodStatus did not call completion")
        }
    }

    // MARK: - 2. testGetDetailedStatus

    /// Pair a fresh pod, call getDetailedStatus (async API), assert detailed fields.
    func testGetDetailedStatus() throws {
        let manager = try pairFreshPod()

        let exp = expectation(description: "getDetailedStatus")
        var detailedStatus: DetailedStatus?
        var detailedError: Error?

        Task {
            do {
                detailedStatus = try await manager.getDetailedStatus()
            } catch {
                detailedError = error
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)

        if let error = detailedError {
            XCTFail("getDetailedStatus threw: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }
        guard let status = detailedStatus else {
            XCTFail("getDetailedStatus returned nil")
            return
        }

        // Fresh pod should be at aboveFiftyUnits (8).
        XCTAssertEqual(
            status.podProgressStatus, PodProgressStatus.aboveFiftyUnits,
            "expected aboveFiftyUnits, got \(status.podProgressStatus)"
        )

        // No fault for a freshly activated, non-faulted pod.
        XCTAssertFalse(status.isFaulted, "fresh pod should not be faulted")

        // Reservoir: see note in testGetPodStatusBasic.
        XCTAssertGreaterThan(
            status.reservoirLevel, 40.0,
            "reservoir should be above 40U for fresh pod, got \(status.reservoirLevel)"
        )

        // Pod uptime (timeActive) should be non-negative.
        XCTAssertGreaterThanOrEqual(status.timeActive, 0, "timeActive should be non-negative")
    }

    // MARK: - 3. testStatusReflectsBolusInProgress

    /// Pair a fresh pod, start a 2.5U bolus, immediately query status while the
    /// bolus delivery window is open, and assert the deliveryStatus reflects an
    /// active bolus.
    ///
    /// The Go sim sets BolusEnd = now + (pulses * 2s). For 2.5U = 50 pulses that
    /// is now + 100s. A status query immediately after enacting the bolus will
    /// see BolusEnd in the future → BolusActive = true → DeliveryStatus.bolusInProgress.
    func testStatusReflectsBolusInProgress() throws {
        let manager = try pairFreshPod()

        // Enact a 2.5U bolus (manual activation type).
        let bolusExp = expectation(description: "enactBolus")
        var bolusError: PumpManagerError?

        manager.enactBolus(units: 2.5, activationType: .manualNoRecommendation) { error in
            bolusError = error
            bolusExp.fulfill()
        }
        wait(for: [bolusExp], timeout: 10.0)

        if let error = bolusError {
            XCTFail("enactBolus failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Immediately query status — bolus window should still be open.
        let statusExp = expectation(description: "getPodStatus-during-bolus")
        var statusResult: PumpManagerResult<StatusResponse>?

        manager.getPodStatus { result in
            statusResult = result
            statusExp.fulfill()
        }
        wait(for: [statusExp], timeout: 10.0)

        switch statusResult {
        case .success(let status):
            // DeliveryStatus should indicate an active bolus.
            let bolusActive = [
                DeliveryStatus.bolusInProgress,
                DeliveryStatus.bolusAndTempBasal,
                DeliveryStatus.extendedBolusRunning,
                DeliveryStatus.extendedBolusAndTempBasal,
            ].contains(status.deliveryStatus)
            XCTAssertTrue(
                bolusActive,
                "expected a bolus-active delivery status, got \(status.deliveryStatus)"
            )
        case .failure(let error):
            XCTFail("getPodStatus failed: \(error)\nstderr: \(self.bridge.stderrTail())")
        case nil:
            XCTFail("getPodStatus did not call completion")
        }
    }

    // MARK: - 4. testStatusReflectsTempBasalActive

    /// Pair a fresh pod, enact a 30-minute temp basal, query status, assert
    /// deliveryStatus reflects the temp basal.
    func testStatusReflectsTempBasalActive() throws {
        let manager = try pairFreshPod()

        // Enact a 1.5 U/hr temp basal for 30 minutes.
        let tbExp = expectation(description: "enactTempBasal")
        var tbError: PumpManagerError?

        manager.enactTempBasal(unitsPerHour: 1.5, for: .minutes(30)) { error in
            tbError = error
            tbExp.fulfill()
        }
        wait(for: [tbExp], timeout: 10.0)

        if let error = tbError {
            XCTFail("enactTempBasal failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Query status — temp basal window should be open.
        let statusExp = expectation(description: "getPodStatus-during-tempBasal")
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
                "expected a temp-basal-active delivery status, got \(status.deliveryStatus)"
            )
        case .failure(let error):
            XCTFail("getPodStatus failed: \(error)\nstderr: \(self.bridge.stderrTail())")
        case nil:
            XCTFail("getPodStatus did not call completion")
        }
    }
}
