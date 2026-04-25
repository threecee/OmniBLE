//
//  PodSimulatorTestCase.swift
//  OmniBLETests
//
//  Base class for integration tests that exercise OmniBLE against the
//  pod-sim Go subprocess. Per-test fresh subprocess (per spec Q7).
//

import XCTest
import CoreBluetooth
import CoreBluetoothMock
@testable import OmniBLE

class PodSimulatorTestCase: XCTestCase {

    var bridge: PodSimulatorBridge!
    var mockPeripheral: MockOmnipodPeripheral!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // 1. Locate the pod-sim binary (Run Script Phase puts it in BUILT_PRODUCTS_DIR)
        let bundle = Bundle(for: type(of: self))
        let binaryURL = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("pod-sim")

        // 2. Spawn the subprocess (fresh state, no auto-disconnect by default)
        bridge = try PodSimulatorBridge(binaryURL: binaryURL, freshState: true, autoDisconnect: false)

        // 3. Configure CBM
        CBMCentralManagerMock.simulateInitialState(.poweredOn)
        mockPeripheral = MockOmnipodPeripheral(bridge: bridge)
        CBMCentralManagerMock.simulatePeripherals([mockPeripheral.makeSpec()])
    }

    override func tearDownWithError() throws {
        bridge?.terminate()
        bridge = nil
        mockPeripheral = nil
        CBMCentralManagerMock.tearDownSimulation()

        // Drain the main runloop so any DispatchQueue.main.async blocks queued
        // by CBMCentralManagerMock.startAdvertising (its Timer.scheduledTimer
        // creation is deferred to main-async) actually fire BEFORE the next
        // test starts. Then call tearDownSimulation again to clear any
        // advertisement timers those late-firing async blocks just registered.
        //
        // Without this, the previous test's startAdvertising async re-runs
        // post-teardown and re-registers an advertisement timer for the
        // PREVIOUS test's spec — which then leaks into the next test's scan
        // results, causing OmniBLE's BluetoothManager to discover BOTH the
        // old and new peripherals. Pairing then deadlocks because the central
        // ends up auto-connecting to the wrong one OR the multi-peripheral
        // scan callbacks corrupt internal sequencing.
        let drainDeadline = Date().addingTimeInterval(0.3)
        while Date() < drainDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        CBMCentralManagerMock.tearDownSimulation()

        try super.tearDownWithError()
    }

    /// Pair a fresh pod via OmniBLEPumpManager. Returns the configured manager.
    /// Times out after 30 seconds (the default pairing flow can take up to ~20s
    /// of real time including BLE round-trips).
    ///
    /// NOTE: This helper's exact implementation depends on the actual
    /// OmniBLEPumpManager.pair API. If the API doesn't match, this will fail
    /// to compile or fail at runtime — escalate rather than guess.
    func pairFreshPod(file: StaticString = #file, line: UInt = #line) throws -> OmniBLEPumpManager {
        // PLACEHOLDER: actual pair-pod flow goes here. For Phase 4 smoke test,
        // we don't need this — the smoke test is connect-only. Phase 5+ will
        // exercise real pairing and refine this helper.
        XCTFail("pairFreshPod not implemented yet; use only connect-level helpers in Phase 4", file: file, line: line)
        throw NSError(domain: "T1", code: 1, userInfo: [NSLocalizedDescriptionKey: "pairFreshPod stub"])
    }

    /// Helper for diagnostics: dump the current stderr from pod-sim. Call from a failing test.
    func dumpPodSimStderr() {
        let tail = bridge.stderrTail(maxBytes: 8192)
        print("=== pod-sim stderr ===")
        print(tail)
        print("=== end stderr ===")
    }
}
