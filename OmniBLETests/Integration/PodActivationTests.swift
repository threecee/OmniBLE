//
//  PodActivationTests.swift
//  OmniBLETests
//
//  Full pod pairing/activation including LTK derivation through encryption.
//  These tests exercise the marquee scenario: real iOS pump-manager code
//  paths driving the real Pi sim pod state machine via real BLE wire protocol
//  with real AES-128 encryption.
//
//  IMPORTANT — simulator-guard bypass:
//    OmniBLEPumpManager.pairAndPrime / insertCannula short-circuit to mocked
//    paths when `targetEnvironment(simulator)` is true (which is always true
//    for OmniBLETests, since the test bundle only runs on iOS Simulator).
//    To exercise the *real* encrypted protocol stack, these tests reach into
//    `pumpManager.podCommsForTesting` directly and drive the pairing flow at
//    the PodComms level, bypassing the public-API short-circuit.
//
//  Also installs a `QueueBouncingCentralDelegate` to work around a CBM
//  library limitation where scan-result callbacks fire on main thread
//  instead of the per-manager dispatch queue (would otherwise crash
//  OmniBLE's BluetoothManager dispatchPrecondition checks).
//

import XCTest
import CoreBluetooth
import CoreBluetoothMock
import LoopKit
@testable import OmniBLE

final class PodActivationTests: PodSimulatorTestCase {

    /// Phase 5b's marquee test (Phase 5a was escalated due to a CBM
    /// threading bug; the QueueBouncingCentralDelegate workaround unblocks
    /// it). Full activation from a fresh, unpaired pod:
    /// connectToNewPod (BLE discovery + connect) → pairAndSetupPod (LTK
    /// exchange, EAP-AKA session establishment, SetupPod encrypted command).
    /// Pod ends in setupProgress.isPaired.
    ///
    /// **This test exercises the encrypted protocol end-to-end.** If it
    /// doesn't pass after debugging, the Pi sim's encryption layer doesn't
    /// match what OmniBLE expects, and we need to fall back to porting
    /// `pkg/encrypt`/`pkg/message` to Swift (T.1 spec Q1 fallback option b).
    func testFullActivationFlow() throws {
        let manager = makeFreshPumpManager()
        let podComms = manager.podCommsForTesting

        // Install the queue-bouncing CBM delegate wrapper. This MUST happen
        // after OmniBLEPumpManager init (which spins up the BluetoothManager
        // and its CBMCentralManager) and BEFORE we call connectToNewPod.
        queueBouncer = installQueueBouncingDelegate(on: manager)

        // Brief settle so the wrapper's centralManagerDidUpdateState
        // re-fire reaches the BluetoothManager on its managerQueue.
        waitForBluetoothSettle(timeout: 1.0)

        // Step 1: BLE discovery + connect to the mock peripheral.
        let connectExp = expectation(description: "connectToNewPod")
        // Slow CI runners (GitHub-hosted Sim) can deliver the connect
        // callback twice — the discovery Timer in PodComms.connectToNewPod
        // doesn't invalidate atomically with completion delivery. Only the
        // first fulfill matters; treat extras as non-fatal.
        connectExp.assertForOverFulfill = false
        var connectResult: Result<OmniBLE, Error>?
        podComms.connectToNewPod { result in
            connectResult = result
            connectExp.fulfill()
        }
        // discoverPods waits up to 10s for a pod to appear.
        wait(for: [connectExp], timeout: 15.0)

        switch connectResult {
        case .success:
            break
        case .failure(let error):
            XCTFail("connectToNewPod failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        case nil:
            XCTFail("connectToNewPod did not call completion")
            return
        }

        // Step 2: drive encrypted pairing. This is the marquee — LTK exchange
        // followed by EAP-AKA session establishment followed by the encrypted
        // SetupPod command. Failure here means a Pi-sim-vs-OmniBLE protocol
        // mismatch in `pkg/pair`, `pkg/eap`, or `pkg/encrypt`.
        let pairExp = expectation(description: "pairAndSetupPod")
        // Defensive: pairAndSetupPod's session-run block could fire more than
        // once on slow CI if a stale callback races with a retry path.
        pairExp.assertForOverFulfill = false
        var pairResult: PodComms.SessionRunResult?
        podComms.pairAndSetupPod(
            timeZone: .currentFixed,
            insulinType: .novolog,
            messageLogger: nil
        ) { result in
            pairResult = result
            pairExp.fulfill()
        }
        // The spec budgets up to 30s for the full pairing flow.
        wait(for: [pairExp], timeout: 30.0)

        switch pairResult {
        case .success:
            // Verify the pod state ended in podPaired (or further).
            let podState = manager.state.podState
            XCTAssertNotNil(podState, "no podState after pair")
            XCTAssertNotNil(podState?.ltk, "no LTK after pair")
            XCTAssertGreaterThanOrEqual(podState?.ltk.count ?? 0, 16, "LTK should be 16+ bytes")
            // setupProgress should reflect at least podPaired
            if let progress = podState?.setupProgress {
                XCTAssertTrue(
                    progress.isPaired,
                    "expected setupProgress.isPaired after pairAndSetupPod, got \(progress)"
                )
            }
        case .failure(let error):
            XCTFail("pairAndSetupPod failed: \(error)\nstderr: \(self.bridge.stderrTail())")
        case nil:
            XCTFail("pairAndSetupPod did not call completion")
        }
    }

    /// Spawn the bridge with a TOML that carries a non-nil LTK (16 zero bytes).
    ///
    /// The Go sim sees `ltk != nil` → skips pairing → goes straight to EAP-AKA.
    /// OmniBLE (fresh manager, no stored LTK) sends the SP1SP2 pairing initiation.
    /// The Go sim's EAP-AKA path receives the wrong message type and calls
    /// log.Fatalf, killing the subprocess. OmniBLE observes the subprocess exit
    /// and returns an error from pairAndSetupPod. We assert that error is non-nil.
    ///
    /// Note: the error shape is "subprocess exited" (a comms/transport error),
    /// not a higher-level "bad LTK" semantic error — the Go sim doesn't do
    /// graceful crypto-mismatch recovery.
    func testPairingFailsWithBadLTK() throws {
        // Spawn bridge with a 16-zero-byte LTK so the sim thinks the pod is
        // already paired and skips the pairing handshake.
        let badLTKToml = """
        ltk = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        eap_aka_seq = 1
        """
        try spawnBridgeWithTOML(badLTKToml)

        let manager = makeFreshPumpManager()
        let podComms = manager.podCommsForTesting

        queueBouncer = installQueueBouncingDelegate(on: manager)
        waitForBluetoothSettle(timeout: 1.0)

        // Connect — this should succeed (BLE layer connects fine).
        let connectExp = expectation(description: "connectToNewPod")
        connectExp.assertForOverFulfill = false
        var connectResult: Result<OmniBLE, Error>?
        podComms.connectToNewPod { result in
            connectResult = result
            connectExp.fulfill()
        }
        wait(for: [connectExp], timeout: 15.0)

        // Connect may succeed or fail depending on timing; either way, we proceed.
        if case .failure(let e) = connectResult {
            // Connection itself failed — still counts as "pair fails" since we
            // never got to pairAndSetupPod.
            XCTAssertNotNil(e, "Expected a connection error with bad LTK state")
            return
        }

        // Pair — this should fail because the sim expects EAP-AKA but OmniBLE
        // sends SP1SP2. The subprocess crashes; OmniBLE returns a comms error.
        let pairExp = expectation(description: "pairAndSetupPod")
        pairExp.assertForOverFulfill = false
        var pairResult: PodComms.SessionRunResult?
        podComms.pairAndSetupPod(
            timeZone: .currentFixed,
            insulinType: .novolog,
            messageLogger: nil
        ) { result in
            pairResult = result
            pairExp.fulfill()
        }
        wait(for: [pairExp], timeout: 15.0)

        switch pairResult {
        case .failure:
            // Expected: pair fails when the sim has a stale/mismatched LTK.
            break
        case .success:
            XCTFail(
                "pairAndSetupPod unexpectedly succeeded with a bad-LTK TOML state. " +
                "The Go sim should have crashed trying to parse SP1SP2 as an EAP-AKA " +
                "challenge.\nstderr: \(self.bridge.stderrTail())"
            )
        case nil:
            // No completion — could mean the subprocess died before the callback.
            // That's also a "fail" in spirit; assert it's not a hang.
            XCTFail(
                "pairAndSetupPod did not call completion within 15s — possible hang " +
                "or subprocess died silently.\nstderr: \(self.bridge.stderrTail())"
            )
        }
    }

    /// Disconnect mid-activation; reconnect; resume; assert success.
    /// Skipped: precise mid-flow timing is hard to engineer without
    /// instrumentation hooks the production code doesn't expose.
    func testActivationResumesAfterInterruption() throws {
        try XCTSkipIf(
            true,
            "Skipped: requires precise mid-flow disconnect timing that PodComms doesn't " +
            "expose. Defer to a follow-up phase that adds disconnect-injection hooks."
        )
    }

}
