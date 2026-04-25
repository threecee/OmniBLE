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

import XCTest
import CoreBluetooth
import CoreBluetoothMock
import LoopKit
@testable import OmniBLE

final class PodActivationTests: PodSimulatorTestCase {

    /// Phase 5's marquee test. Full activation from a fresh, unpaired pod:
    /// connectToNewPod (BLE discovery + connect) → pairAndSetupPod (LTK exchange,
    /// EAP-AKA session establishment, SetupPod encrypted command). Pod ends in
    /// the `.podPaired` setup state.
    ///
    /// **CURRENTLY SKIPPED — see ESCALATION below.**
    ///
    /// Phase 5 progress made (preserved in this branch):
    ///   1. Identified that `OmniBLEPumpManager.pairAndPrime` short-circuits
    ///      to a mock-only path under `#if targetEnvironment(simulator)`.
    ///      Added `OmniBLEPumpManager.podCommsForTesting` (internal accessor)
    ///      so this test can drive `PodComms.pairAndSetupPod` directly,
    ///      bypassing the simulator guard.
    ///   2. Discovered CoreBluetoothMock was statically linked into BOTH the
    ///      OmniBLE framework AND the OmniBLETests bundle, giving them
    ///      separate static `managerState`. Removed the duplicate link from
    ///      OmniBLETests so both share the OmniBLE framework's CBM symbols.
    ///   3. Fixed the mock peripheral's advertisement to include the
    ///      DASH-advertisement UUID (00004024-...) that OmniBLE's
    ///      BluetoothManager scans for, in addition to the full service UUID.
    ///   4. Made the pod-sim build script's codesign idempotent (--force),
    ///      so re-builds don't fail on already-signed binaries.
    ///
    /// **ESCALATION — true blocker discovered:**
    ///
    /// `BluetoothManager.centralManager(_:didDiscover:...)` and similar
    /// delegate methods in OmniBLE's production code call
    /// `dispatchPrecondition(condition: .onQueue(managerQueue))`. The
    /// CoreBluetoothMock library (`CBMCentralManagerMock.notify(_:for:)`,
    /// line 247) calls these delegates **synchronously from a main-thread
    /// NSTimer**, without dispatching to the per-manager queue that was
    /// passed at init time. The dispatchPrecondition then crashes with
    /// `_dispatch_assert_queue_fail`.
    ///
    /// This is a CBM library limitation, NOT a Pi-sim/OmniBLE protocol
    /// mismatch. It would affect ANY test that drives OmniBLE's
    /// BluetoothManager via its real delegate path.
    ///
    /// **Fallback options** (per T.1 spec Q1):
    ///   - (a) Extend budget: investigate whether CBM upstream has fixed this
    ///         in a newer version, OR write a wrapper delegate that bounces
    ///         every callback onto the right queue (intrusive — touches all
    ///         BluetoothManager delegate methods + similar in PeripheralManager).
    ///   - (b) Port `pkg/encrypt`/`pkg/message`/`pkg/pair` from Go to Swift,
    ///         then test the encrypted protocol layer in pure-Swift unit
    ///         tests without needing CBM at all.
    ///   - (c) Descope T.1 marquee test; rely on existing direct-CBM tests
    ///         (PodConnectionTests) to validate the wire-level protocol and
    ///         on hardware integration testing (real pod) to validate the
    ///         encrypted layer.
    ///
    /// Recommendation: **(a) with bounded budget** — the wrapper-delegate
    /// approach is concrete (~1-2 days). If it doesn't work cleanly, fall
    /// back to (c) and document.
    func testFullActivationFlow() throws {
        try XCTSkipIf(
            true,
            """
            ESCALATED — see file header.
            CoreBluetoothMock fires its scan/connect delegate callbacks on the
            main thread (from NSTimer) without honoring the per-manager dispatch
            queue. OmniBLE's BluetoothManager has dispatchPrecondition checks
            on a private background managerQueue, causing _dispatch_assert_queue_fail
            on first didDiscover.

            Phase 5 reached this gate after fixing 4 prior infra issues
            (simulator guard, CBM duplicate-linking, advertisement UUID,
            codesign idempotency). The marquee test wiring is in place —
            commented-out body below — and ready for whichever fallback the
            user picks. Recommend option (a): wrapper delegate that bounces
            CBM callbacks onto the expected queue.
            """
        )

        // --- Marquee test body — kept for the eventual unblocking, do not
        //     delete. Wired up correctly through the discovered blocker. ---
        /*
        let manager = makeUnpairedPumpManager()
        let podComms = manager.podCommsForTesting
        waitForBluetoothPoweredOn(timeout: 1.0)

        let connectExp = expectation(description: "connectToNewPod")
        var connectResult: Result<OmniBLE, Error>?
        podComms.connectToNewPod { result in
            connectResult = result
            connectExp.fulfill()
        }
        wait(for: [connectExp], timeout: 15.0)

        switch connectResult {
        case .success: break
        case .failure(let error):
            XCTFail("connectToNewPod failed: \(error)\nstderr: \(self.bridge.stderrTail())")
            return
        case nil:
            XCTFail("connectToNewPod did not call completion")
            return
        }

        let pairExp = expectation(description: "pairAndSetupPod")
        var pairResult: PodComms.SessionRunResult?
        podComms.pairAndSetupPod(
            timeZone: .currentFixed,
            insulinType: .novolog,
            messageLogger: nil
        ) { result in
            pairResult = result
            pairExp.fulfill()
        }
        wait(for: [pairExp], timeout: 30.0)

        switch pairResult {
        case .success:
            let podState = manager.state.podState
            XCTAssertNotNil(podState, "no podState after pair")
            XCTAssertNotNil(podState?.ltk, "no LTK after pair")
            XCTAssertGreaterThanOrEqual(podState?.ltk.count ?? 0, 16, "LTK should be 16+ bytes")
            if let progress = podState?.setupProgress {
                XCTAssertTrue(progress.isPaired, "expected setupProgress.isPaired, got \(progress)")
            }
        case .failure(let error):
            XCTFail("pairAndSetupPod failed: \(error)\nstderr: \(self.bridge.stderrTail())")
        case nil:
            XCTFail("pairAndSetupPod did not call completion")
        }
        */
    }

    /// TOML pre-load with corrupted LTK; pair should fail with a specific error.
    /// Skipped: the bridge's TOML pre-load infra isn't yet wired into
    /// PodSimulatorTestCase, AND it depends on testFullActivationFlow's
    /// blocker being resolved first (this test exercises the same code path).
    func testPairingFailsWithBadLTK() throws {
        try XCTSkipIf(
            true,
            "Skipped: needs PodSimulatorTestCase support for spawning the bridge with -state " +
            "<custom-toml> AND depends on testFullActivationFlow's CBM-threading blocker " +
            "being resolved first (same code path)."
        )
    }

    /// Disconnect mid-activation; reconnect; resume; assert success.
    /// Skipped: precise mid-flow timing is hard to engineer without
    /// instrumentation hooks the production code doesn't expose, AND it
    /// depends on the same CBM-threading blocker.
    func testActivationResumesAfterInterruption() throws {
        try XCTSkipIf(
            true,
            "Skipped: requires precise mid-flow disconnect timing that PodComms doesn't " +
            "expose AND depends on testFullActivationFlow's CBM-threading blocker " +
            "being resolved first (same code path)."
        )
    }

    // MARK: - Helpers

    /// Brief settling pause to let CBMCentralManagerMock's per-instance
    /// initialization async dispatch fire on whatever queue OmniBLE's
    /// BluetoothManager passed at init time (it's a private background queue
    /// we can't observe directly). 500ms is plenty in practice.
    private func waitForBluetoothPoweredOn(timeout: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Build a fresh unpaired OmniBLEPumpManager wired to use the CBM-mock
    /// BluetoothManager (CBMCentralManagerFactory returns the mock under
    /// targetEnvironment(simulator), so OmniBLE's BluetoothManager picks up
    /// our registered MockOmnipodPeripheral automatically).
    private func makeUnpairedPumpManager() -> OmniBLEPumpManager {
        let state = OmniBLEPumpManagerState(
            podState: nil,
            timeZone: .currentFixed,
            basalSchedule: BasalSchedule(entries: [
                BasalScheduleEntry(rate: 1.0, startTime: 0)
            ]),
            insulinType: .novolog,
            maximumTempBasalRate: 5.0
        )
        return OmniBLEPumpManager(state: state)
    }
}
