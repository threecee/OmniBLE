//
//  PodAlertsTests.swift
//  OmniBLETests
//
//  Alert-handling integration tests against the Pi sim.
//
//  Go sim alert architecture:
//    The Go sim (pkg/pod/pod.go) supports SetAlerts(uint8) and SetFault(uint8)
//    methods, but these are NOT exposed via the bridge wire protocol — they are
//    only callable internally. Faulted state is injected via the TOML pre-load
//    infrastructure added in T.1 follow-up (pairThenRespawnWithMutatedTOML).
//
//    testAcknowledgeAlert: A fresh pod carries no active alerts — this test
//      exercises acknowledgePodAlerts with AlertSet.none (no-op ack), which
//      succeeds because the session layer sends the AcknowledgeAlertCommand and
//      the pod responds with its current (empty) alert slot bitmask.
//
//    testFaultedPodReportsCorrectly and testAcknowledgeFault:
//      Both now use pairThenRespawnWithMutatedTOML to inject FaultEvent = 0xae
//      into the pod state after pairing and respawn the subprocess with the
//      mutated TOML. The same manager is reused for reconnect (matching LTK).
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

    /// Two-phase test using TOML state mutation:
    ///   Phase 1 — pair a fresh pod (full activation), capturing state to a temp file.
    ///   Phase 2 — inject FaultEvent = 0xae into the TOML; respawn the bridge; reconnect
    ///             with the same manager (matching LTK → EAP-AKA succeeds); call
    ///             getDetailedStatus(); assert isFaulted == true and rawValue == 0xae.
    ///
    /// FaultEvent = 0xae (174 decimal) is "reservoir empty" in Omnipod firmware.
    /// The Go sim encodes it at byte 10 of the DetailedStatusResponse; Swift's
    /// DetailedStatus.isFaulted returns true whenever faultEventCode.rawValue != 0.
    func testFaultedPodReportsCorrectly() throws {
        let manager = try pairThenRespawnWithMutatedTOML { toml in
            if toml.contains("fault =") {
                toml = toml.replacingOccurrences(
                    of: #"fault = \d+"#,
                    with: "fault = 174",
                    options: .regularExpression
                )
            } else {
                toml += "\nfault = 174\n"
            }
        }

        queueBouncer = installQueueBouncingDelegate(on: manager)
        waitForBluetoothSettle(timeout: 1.0)

        let statusExp = expectation(description: "getDetailedStatus on faulted pod")
        var detailedStatus: DetailedStatus?
        var statusError: Error?

        Task {
            do {
                detailedStatus = try await manager.getDetailedStatus()
            } catch {
                statusError = error
            }
            statusExp.fulfill()
        }
        wait(for: [statusExp], timeout: 30.0)

        if let error = statusError {
            XCTFail(
                "getDetailedStatus failed: \(error)\nstderr: \(self.bridge.stderrTail())\n" +
                "Note: if the error is a BLE timeout, the reconnect to the respawned subprocess " +
                "may not have fired. pairThenRespawnWithMutatedTOML reuses the peripheral UUID " +
                "so CBM should reconnect, but BluetoothManager's reconnect debounce may delay."
            )
            return
        }

        guard let status = detailedStatus else {
            XCTFail("getDetailedStatus returned nil without error")
            return
        }

        XCTAssertTrue(
            status.isFaulted,
            "Expected isFaulted=true for FaultEvent=0xae, got faultEventCode=\(status.faultEventCode)"
        )
        XCTAssertEqual(
            status.faultEventCode.rawValue, 0xae,
            "Expected faultEventCode 0xae (174), got \(status.faultEventCode.rawValue)"
        )
    }

    // MARK: - 18. testAcknowledgeFault

    /// Two-phase test: pair fresh pod; inject FaultEvent = 0xae via TOML mutation;
    /// respawn; reconnect with same manager; call acknowledgePodAlerts; assert success.
    ///
    /// "Acknowledging a fault" in OmniBLE's API maps to acknowledgePodAlerts
    /// (SilenceAlerts / 0x11 command). The Go sim clears the alert slot bitmask in
    /// response. The FaultEvent itself is not cleared (faults are sticky in the real
    /// pod); the important assertion is that the session completes without error even
    /// when the pod is in a faulted state.
    func testAcknowledgeFault() throws {
        let manager = try pairThenRespawnWithMutatedTOML { toml in
            if toml.contains("fault =") {
                toml = toml.replacingOccurrences(
                    of: #"fault = \d+"#,
                    with: "fault = 174",
                    options: .regularExpression
                )
            } else {
                toml += "\nfault = 174\n"
            }
        }

        queueBouncer = installQueueBouncingDelegate(on: manager)
        waitForBluetoothSettle(timeout: 1.0)

        let ackExp = expectation(description: "acknowledgePodAlerts on faulted pod")
        var returnedAlerts: AlertSet?
        var didCall = false

        manager.acknowledgePodAlerts(AlertSet(rawValue: ~0)) { alerts in
            returnedAlerts = alerts
            didCall = true
            ackExp.fulfill()
        }
        wait(for: [ackExp], timeout: 30.0)

        XCTAssertTrue(didCall, "acknowledgePodAlerts completion not called within 30s")
        // returnedAlerts may be nil if the session errored; log stderr for diagnostics.
        if returnedAlerts == nil {
            XCTFail(
                "acknowledgePodAlerts returned nil (session error on faulted pod?)\n" +
                "stderr: \(self.bridge.stderrTail())"
            )
        }
    }
}
