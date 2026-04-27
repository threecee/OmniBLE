//
//  PodDeactivationTests.swift
//  OmniBLETests
//
//  Deactivation integration tests against the Pi sim. Each test pairs a fresh
//  pod (full activation flow), then calls deactivatePod and asserts the
//  expected outcome.
//
//  API surface (from OmniBLEPumpManager.swift):
//    deactivatePod(completion:)  — sends 0x1c DeactivatePodCommand; on success
//                                  the Go sim sets DeactivateFlag=true and
//                                  stops accepting new commands.
//    forgetPod(completion:)      — clears podState and resets pump manager state
//                                  (normally called by UI after deactivatePod).
//
//  Go sim behaviour after deactivation:
//    pkg/pod/pod.go sets DeactivateFlag=true on receipt of 0x1c. The state
//    machine exits cleanly after that response. The Swift side's podComms
//    session ends; subsequent BLE operations will fail with a session / comms
//    error because the pod process has shut down.
//
//  Tests are numbered starting at 19 (continuing from Phase 7 alerts tests).
//

import XCTest
import CoreBluetoothMock
import LoopKit
@testable import OmniBLE

final class PodDeactivationTests: PodSimulatorTestCase {

    // MARK: - 19. testDeactivateActivePod

    /// Pair a fresh pod, deactivate it, assert:
    ///   1. deactivatePod completes without error.
    ///   2. forgetPod clears the pod state (hasActivePod becomes false).
    ///
    /// After deactivation the Go sim's state machine exits. Any subsequent
    /// BLE operation would fail — this is expected and not asserted here
    /// (asserting subsequent failure would require a reconnect attempt which
    /// would block indefinitely since the pod-sim subprocess has exited its
    /// state machine loop).
    func testDeactivateActivePod() throws {
        let manager = try pairFreshPod()

        // Confirm pod is active before deactivation.
        XCTAssertTrue(manager.hasActivePod, "pod should be active before deactivation")

        // Deactivate the pod.
        let deactivateExp = expectation(description: "deactivatePod")
        var deactivateError: OmniBLEPumpManagerError?

        manager.deactivatePod { error in
            deactivateError = error
            deactivateExp.fulfill()
        }
        wait(for: [deactivateExp], timeout: 20.0)

        if let error = deactivateError {
            XCTFail("deactivatePod failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // Call forgetPod to clear the pod state (mirrors production UI flow).
        let forgetExp = expectation(description: "forgetPod")

        manager.forgetPod {
            forgetExp.fulfill()
        }
        wait(for: [forgetExp], timeout: 10.0)

        // Assert the manager no longer has an active pod.
        XCTAssertFalse(
            manager.hasActivePod,
            "hasActivePod should be false after deactivatePod + forgetPod"
        )
        XCTAssertNil(
            manager.state.podState,
            "podState should be nil after deactivatePod + forgetPod"
        )
    }

    // MARK: - 20. testDeactivateFaultedPod

    /// Two-phase test: pair fresh pod; inject FaultEvent = 0xae via TOML mutation;
    /// respawn; reconnect with same manager; call deactivatePod; assert success.
    ///
    /// PodCommsSession.deactivatePod explicitly catches .podFault errors and
    /// continues through to the 0x1c DeactivatePodCommand, so a faulted pod
    /// should still be deactivatable. After deactivation, forgetPod clears pod state.
    func testDeactivateFaultedPod() throws {
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

        XCTAssertTrue(manager.hasActivePod, "pod should be active after respawn with fault")

        // Deactivate — should succeed even with FaultEvent = 0xae because
        // PodCommsSession.deactivatePod tolerates .podFault errors.
        let deactivateExp = expectation(description: "deactivatePod on faulted pod")
        var deactivateError: OmniBLEPumpManagerError?

        manager.deactivatePod { error in
            deactivateError = error
            deactivateExp.fulfill()
        }
        wait(for: [deactivateExp], timeout: 30.0)

        if let error = deactivateError {
            XCTFail(
                "deactivatePod on faulted pod failed: \(error)\n" +
                "stderr: \(self.bridge.stderrTail())\n" +
                "Note: PodCommsSession.deactivatePod catches .podFault — if this fails with " +
                "a comms error the issue may be reconnect timing to the respawned subprocess."
            )
            return
        }

        // forgetPod to clear state.
        let forgetExp = expectation(description: "forgetPod")
        manager.forgetPod { forgetExp.fulfill() }
        wait(for: [forgetExp], timeout: 10.0)

        XCTAssertFalse(
            manager.hasActivePod,
            "hasActivePod should be false after deactivatePod + forgetPod on faulted pod"
        )
    }
}
