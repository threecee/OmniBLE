//
//  PodAlertsTests.swift
//  OmniBLETests
//
//  Alert-handling integration tests against the Pi sim.
//
//  Go sim alert architecture:
//    The Go sim (pkg/pod/pod.go) supports SetAlerts(uint8) and SetFault(uint8)
//    methods, but these are NOT exposed via the bridge wire protocol — they are
//    only callable internally. As a result:
//
//    testAcknowledgeAlert: A fresh pod carries no active alerts — the pod sets
//      alerts via TOML pre-load or timer-based internal logic; neither path is
//      accessible from the test harness today. This test exercises
//      acknowledgePodAlerts with AlertSet.none (no-op ack), which always
//      succeeds because the session layer sends the AcknowledgeAlertCommand and
//      the pod responds with its current (empty) alert slot bitmask.
//
//    testFaultedPodReportsCorrectly and testAcknowledgeFault:
//      Both require pre-loading the Go sim with a faulted pod state via TOML.
//      The bridge currently only supports -fresh (blank pod) — there is no
//      -state <toml> flag wired into PodSimulatorBridge yet. Skipped with a
//      detailed note for a follow-up phase.
//
//  Tests are numbered starting at 16 (continuing from Phase 7 suspend/resume tests).
//

import XCTest
import CoreBluetoothMock
import LoopKit
@testable import OmniBLE

final class PodAlertsTests: PodSimulatorTestCase {

    // MARK: - 16. testAcknowledgeAlert

    /// Pair a fresh pod and call acknowledgePodAlerts with all bits set
    /// (AlertSet(rawValue: ~0)). The Go sim will receive the SilenceAlerts
    /// command and clear any active alert slots (there are none on a fresh pod).
    /// Assert the call completes and returns a non-nil AlertSet.
    ///
    /// This exercises the full encrypted session path for the AcknowledgeAlerts
    /// command even though no alerts are actually active on a fresh pod.
    ///
    /// Note: On a fresh pod the active alert slots bitmask is 0, so the returned
    /// AlertSet should be equal to AlertSet.none. The important assertion is that
    /// the call does NOT error — the session layer successfully sends and receives
    /// the encrypted response.
    func testAcknowledgeAlert() throws {
        let manager = try pairFreshPod()

        // Acknowledge all alert slots (fresh pod → bitmask 0 → no-op at pod side).
        let ackExp = expectation(description: "acknowledgePodAlerts")
        var returnedAlerts: AlertSet?
        var didCall = false

        manager.acknowledgePodAlerts(AlertSet(rawValue: ~0)) { alerts in
            returnedAlerts = alerts
            didCall = true
            ackExp.fulfill()
        }
        wait(for: [ackExp], timeout: 15.0)

        XCTAssertTrue(
            didCall,
            "acknowledgePodAlerts completion should have been called"
        )

        // On a fresh pod, the acknowledgement should succeed and return an AlertSet.
        // A nil return means the session failed (pod returned an error or comms failed).
        XCTAssertNotNil(
            returnedAlerts,
            "acknowledgePodAlerts returned nil (session failure); stderr: \(self.bridge.stderrTail())"
        )

        if let alerts = returnedAlerts {
            // Fresh pod has no active alerts — returned set should be empty.
            XCTAssertEqual(
                alerts.rawValue, AlertSet.none.rawValue,
                "fresh pod should have no active alerts after acknowledgement, got rawValue=\(alerts.rawValue)"
            )
        }
    }

    // MARK: - 17. testFaultedPodReportsCorrectly

    /// Skipped: requires TOML pre-load to start the Go sim bridge with a pod
    /// already in a faulted state (FaultEvent != 0, FaultTime set).
    ///
    /// The Go sim's SetFault(uint8) method exists in pkg/pod/pod.go but is not
    /// exposed via the bridge wire protocol — it can only be triggered by
    /// pre-loading pod state via the -state <toml> flag. PodSimulatorBridge
    /// currently only supports -fresh (blank pod); adding -state <toml> spawn
    /// support requires extending PodSimulatorBridge.init to accept an optional
    /// TOML content parameter and writing that content to a temp file.
    ///
    /// What would be tested:
    ///   - Spawn bridge with FaultEvent = 0xae (e.g., reservoir empty fault)
    ///   - Call manager.getDetailedStatus()
    ///   - Assert status.isFaulted == true
    ///   - Assert status.faultEventCode != 0
    ///
    /// Deferred to a follow-up phase that adds TOML-preload bridge support.
    func testFaultedPodReportsCorrectly() throws {
        try XCTSkipIf(
            true,
            "Skipped: requires PodSimulatorBridge -state <toml> spawn support to pre-load a " +
            "faulted pod state (FaultEvent != 0). The Go sim's SetFault() is not exposed via " +
            "the bridge wire protocol. Defer to a follow-up phase adding TOML pre-load support."
        )
    }

    // MARK: - 18. testAcknowledgeFault

    /// Skipped: same prerequisite as testFaultedPodReportsCorrectly — requires
    /// TOML pre-load to put the pod in a faulted state before testing the
    /// fault acknowledgement path.
    ///
    /// What would be tested:
    ///   - Spawn bridge with FaultEvent != 0
    ///   - Call manager.deactivatePod() (which internally does acknowledgeAlerts
    ///     + reads pulse log + sends DeactivatePodCommand, tolerating the fault)
    ///   - Assert deactivation completes without a non-fault error
    ///
    /// Deferred to the same follow-up phase as testFaultedPodReportsCorrectly.
    func testAcknowledgeFault() throws {
        try XCTSkipIf(
            true,
            "Skipped: requires TOML pre-load for faulted pod state. Same prerequisite " +
            "as testFaultedPodReportsCorrectly. Defer to TOML pre-load follow-up phase."
        )
    }
}
