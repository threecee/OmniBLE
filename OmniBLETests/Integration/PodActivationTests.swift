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

    /// Held for the lifetime of each test so CBM (which uses weak delegate
    /// references) doesn't drop our queue-bouncing wrapper.
    private var queueBouncer: QueueBouncingCentralDelegate?

    override func tearDownWithError() throws {
        queueBouncer = nil
        try super.tearDownWithError()
    }

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
        let manager = makeUnpairedPumpManager()
        let podComms = manager.podCommsForTesting

        // Install the queue-bouncing CBM delegate wrapper. This MUST happen
        // after OmniBLEPumpManager init (which spins up the BluetoothManager
        // and its CBMCentralManager) and BEFORE we call connectToNewPod.
        queueBouncer = installQueueBouncingDelegate(on: manager)

        // Brief settle so the wrapper's centralManagerDidUpdateState
        // re-fire reaches the BluetoothManager on its managerQueue.
        waitForBluetoothPoweredOn(timeout: 1.0)

        // Step 1: BLE discovery + connect to the mock peripheral.
        let connectExp = expectation(description: "connectToNewPod")
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

    /// TOML pre-load with corrupted LTK; pair should fail with a specific error.
    /// Skipped: the bridge's TOML pre-load infra isn't yet wired into
    /// PodSimulatorTestCase. Once testFullActivationFlow is solidly passing,
    /// this is straightforward to add.
    func testPairingFailsWithBadLTK() throws {
        try XCTSkipIf(
            true,
            "Skipped: needs PodSimulatorTestCase support for spawning the bridge with -state " +
            "<custom-toml> and a TOML schema for injecting a corrupted LTK. Defer to follow-up."
        )
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
