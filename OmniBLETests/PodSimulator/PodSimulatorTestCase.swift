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
import LoopKit
@testable import OmniBLE

class PodSimulatorTestCase: XCTestCase {

    var bridge: PodSimulatorBridge!
    var mockPeripheral: MockOmnipodPeripheral!

    /// Held for the lifetime of each test so CBM (which uses weak delegate
    /// references) doesn't drop our queue-bouncing wrapper.
    var queueBouncer: QueueBouncingCentralDelegate?

    /// Minimal stub delegate wired to the pump manager so that
    /// OmniBLEPumpManager.store(doses:) doesn't fatal-error on a nil delegate.
    /// Held strongly here (the manager stores it weakly).
    var mockDelegate: MockPumpManagerDelegate?

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
        queueBouncer = nil
        mockDelegate = nil
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

        // Clean up any temp TOML files written by spawnBridgeWithTOML /
        // pairThenRespawnWithMutatedTOML.
        for url in tomlTempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tomlTempFiles.removeAll()

        try super.tearDownWithError()
    }

    // MARK: - TOML pre-load helpers

    /// Tracks temp files written by `spawnBridgeWithTOML` so tearDown can
    /// clean them up.
    var tomlTempFiles: [URL] = []

    /// Spawn the pod-sim subprocess with a pre-loaded TOML state instead of
    /// `-fresh`. The TOML content is written to a unique temp file; the bridge
    /// is respawned with `-state <tempfile>` (omitting `-fresh`).
    ///
    /// Tear down the existing bridge from setUpWithError first (if any), then
    /// rebuild `self.bridge` and `self.mockPeripheral` with the new subprocess.
    ///
    /// Use this for tests that need the pod in a specific non-default state.
    /// Call from the test body before doing any BLE operations.
    func spawnBridgeWithTOML(_ tomlContent: String) throws {
        // 1. Write tomlContent to a unique temp file.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pod-sim-\(UUID().uuidString).toml")
        try tomlContent.write(to: tempURL, atomically: true, encoding: .utf8)
        tomlTempFiles.append(tempURL)

        // 2. Tear down the existing subprocess (spawned in setUpWithError).
        bridge?.terminate()
        bridge = nil
        CBMCentralManagerMock.tearDownSimulation()
        // Brief drain so CBM internals can settle before we re-configure.
        let drainDeadline = Date().addingTimeInterval(0.2)
        while Date() < drainDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        CBMCentralManagerMock.tearDownSimulation()

        // 3. Locate the pod-sim binary (same path as setUpWithError uses).
        let bundle = Bundle(for: type(of: self))
        let binaryURL = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("pod-sim")

        // 4. Respawn with -state <tempfile> (no -fresh).
        bridge = try PodSimulatorBridge(binaryURL: binaryURL, freshState: false, stateFileURL: tempURL, autoDisconnect: false)

        // 5. Re-configure CBM with the new bridge.
        CBMCentralManagerMock.simulateInitialState(.poweredOn)
        mockPeripheral = MockOmnipodPeripheral(bridge: bridge)
        CBMCentralManagerMock.simulatePeripherals([mockPeripheral.makeSpec()])
    }

    /// Pair a fresh pod, save its state, terminate the subprocess, mutate the
    /// saved TOML (e.g., inject a fault code), then respawn with the mutated state.
    ///
    /// Returns the `OmniBLEPumpManager` from the initial pairing. Because the
    /// manager holds the real LTK from pairing, it can reconnect to the new
    /// (respawned) subprocess via EAP-AKA without re-pairing. Callers must
    /// re-install a `QueueBouncingCentralDelegate` on the returned manager and
    /// settle before calling `runSession` or any BLE operation.
    ///
    /// On return, `self.bridge` and `self.mockPeripheral` point at the new
    /// subprocess running the mutated state.
    ///
    /// Use this to pre-load a fully-paired pod state with selective mutations
    /// (e.g., inject a fault code). The two-phase approach is necessary because
    /// the crypto state (LTK, CK, nonces) can only be generated via a real
    /// pairing exchange — it cannot be synthesised synthetically.
    @discardableResult
    func pairThenRespawnWithMutatedTOML(
        mutateTOML: (inout String) -> Void,
        file: StaticString = #file,
        line: UInt = #line
    ) throws -> OmniBLEPumpManager {
        // 1. Use a unique temp path for the state file so we know where saves land.
        let stateTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pod-sim-state-\(UUID().uuidString).toml")
        tomlTempFiles.append(stateTempURL)

        // Tear down the bridge spawned in setUpWithError and respawn with
        // the same temp state file path (still fresh — the sim writes to it
        // after pairing completes).
        bridge?.terminate()
        bridge = nil
        CBMCentralManagerMock.tearDownSimulation()
        let drainDeadline = Date().addingTimeInterval(0.2)
        while Date() < drainDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        CBMCentralManagerMock.tearDownSimulation()

        let bundle = Bundle(for: type(of: self))
        let binaryURL = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("pod-sim")

        // Spawn fresh with the temp state path so Save() writes there.
        bridge = try PodSimulatorBridge(
            binaryURL: binaryURL,
            freshState: true,
            stateFileURL: stateTempURL,
            autoDisconnect: false
        )
        CBMCentralManagerMock.simulateInitialState(.poweredOn)
        mockPeripheral = MockOmnipodPeripheral(bridge: bridge)
        CBMCentralManagerMock.simulatePeripherals([mockPeripheral.makeSpec()])

        // 2. Pair and fully activate. By the end, stateTempURL holds the
        //    fully-activated session state (LTK, CK, nonces, PodProgress, etc.).
        let pairedManager = try pairFreshPod(file: file, line: line)

        // 3. Terminate the subprocess cleanly. The state file is already written.
        bridge.terminate()
        bridge = nil
        CBMCentralManagerMock.tearDownSimulation()
        let drainDeadline2 = Date().addingTimeInterval(0.3)
        while Date() < drainDeadline2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        CBMCentralManagerMock.tearDownSimulation()

        // 4. Read the saved TOML, apply caller's mutation, write back.
        var toml = try String(contentsOf: stateTempURL, encoding: .utf8)
        mutateTOML(&toml)
        try toml.write(to: stateTempURL, atomically: true, encoding: .utf8)

        // 5. Respawn with the mutated state. The Go sim will read the real LTK
        //    and go directly to EAP-AKA on next connect. The returned manager
        //    also holds the real LTK, so EAP-AKA will succeed on reconnect.
        //
        //    IMPORTANT: reuse the same peripheral UUID from the pairing session.
        //    podComms stores the paired pod's BLE identifier and will only
        //    auto-reconnect to a peripheral with that exact UUID. If we registered
        //    a new UUID, reconnect would never match.
        let pairedPeripheralID = mockPeripheral.identifier

        bridge = try PodSimulatorBridge(
            binaryURL: binaryURL,
            freshState: false,
            stateFileURL: stateTempURL,
            autoDisconnect: false
        )
        CBMCentralManagerMock.simulateInitialState(.poweredOn)
        mockPeripheral = MockOmnipodPeripheral(bridge: bridge, identifier: pairedPeripheralID)
        CBMCentralManagerMock.simulatePeripherals([mockPeripheral.makeSpec()])

        return pairedManager
    }

    // MARK: - pairFreshPod

    /// Pair and fully activate a fresh pod. Returns an OmniBLEPumpManager whose pod
    /// is in setupProgress == .completed (i.e., hasActivePod == true), ready for
    /// bolus, temp-basal, and status operations.
    ///
    /// Flow (mirrors what OmniBLEPumpManager.pairAndPrime + insertCannula do on a
    /// real device, bypassing the #if targetEnvironment(simulator) short-circuits):
    ///   1. Build a fresh unpaired OmniBLEPumpManager
    ///   2. Install the queue-bouncing delegate wrapper (required to avoid
    ///      BluetoothManager.dispatchPrecondition crashes with CBM)
    ///   3. Settle for Bluetooth powered-on re-fire
    ///   4. connectToNewPod (BLE discovery + connect)
    ///   5. pairAndSetupPod (LTK exchange + EAP-AKA + SetupPod)
    ///   6. prime (sends FaultConfig + configureAlerts + priming-bolus schedule)
    ///   7. programInitialBasalSchedule (sets the basal program)
    ///   8. insertCannula (sends cannula-insertion bolus)
    ///   9. checkInsertionCompleted (GetStatus → advances pod to aboveFiftyUnits)
    ///
    /// Times out at 60s (the full activation flow can take ~30s on a loaded machine).
    func pairFreshPod(file: StaticString = #file, line: UInt = #line) throws -> OmniBLEPumpManager {
        let manager = makeFreshPumpManager()
        let podComms = manager.podCommsForTesting

        // Install queue-bouncing wrapper. MUST happen before connectToNewPod.
        queueBouncer = installQueueBouncingDelegate(on: manager)

        // Settle so the wrapper's centralManagerDidUpdateState re-fire reaches
        // BluetoothManager on its private managerQueue.
        waitForBluetoothSettle(timeout: 1.0)

        // ── Step 4: BLE discovery + connect ──────────────────────────────────
        let connectExp = expectation(description: "connectToNewPod")
        var connectResult: Result<OmniBLE, Error>?
        podComms.connectToNewPod { result in
            connectResult = result
            connectExp.fulfill()
        }
        wait(for: [connectExp], timeout: 15.0)
        switch connectResult {
        case .success: break
        case .failure(let e):
            XCTFail("connectToNewPod failed: \(e)\nstderr: \(self.bridge.stderrTail())", file: file, line: line)
            throw e
        case nil:
            let e = NSError(domain: "T1", code: 2, userInfo: [NSLocalizedDescriptionKey: "connectToNewPod: no completion"])
            XCTFail(e.localizedDescription, file: file, line: line); throw e
        }

        // ── Step 5: LTK exchange + EAP-AKA + SetupPod ───────────────────────
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
        case .success: break
        case .failure(let e):
            XCTFail("pairAndSetupPod failed: \(e)\nstderr: \(self.bridge.stderrTail())", file: file, line: line)
            throw e
        case nil:
            let e = NSError(domain: "T1", code: 3, userInfo: [NSLocalizedDescriptionKey: "pairAndSetupPod: no completion"])
            XCTFail(e.localizedDescription, file: file, line: line); throw e
        }

        // ── Steps 6–9: prime → basal schedule → insert cannula → check ───────
        //
        // runSession serialises on the session queue. We drive all three steps
        // inside a single session callback to avoid queue re-entrancy issues and
        // to minimise round-trip overhead.
        let setupExp = expectation(description: "fullSetup")
        var setupError: Error?
        podComms.runSession(withName: "Phase 6 pairFreshPod full setup") { result in
            defer { setupExp.fulfill() }
            guard case .success(let session) = result else {
                if case .failure(let e) = result { setupError = e }
                return
            }
            do {
                // 6. Prime
                // We call prime() to send the priming command to the Go sim (which
                // advances PodProgress to .priming) and to set podState.primeFinishTime.
                // The returned primeWait (≈55s) is the real-time duration until priming
                // would complete. We do NOT sleep for it here because:
                //   (a) The Go sim advances PodProgress immediately on receipt of the
                //       prime command, without any real-time enforcement.
                //   (b) session.insertCannula() does not check readyForCannulaInsertion
                //       (that guard is only on the public OmniBLEPumpManager.insertCannula).
                // Simply discard the wait value and proceed immediately.
                _ = try session.prime()

                // 7. Program the initial basal schedule
                let scheduleOffset = TimeZone.currentFixed.scheduleOffset(forDate: Date())
                try session.programInitialBasalSchedule(
                    BasalSchedule(entries: [BasalScheduleEntry(rate: 1.0, startTime: 0)]),
                    scheduleOffset: scheduleOffset
                )

                // 8. Insert cannula (sends cannula-insertion bolus to the sim).
                // We discard the returned cannulaWait (≈11s) for the same reason as
                // the prime wait: the Go sim's GetStatus handler immediately advances
                // PodProgress from insertingCannula to runningAbove50U, so no real-time
                // wait is needed before checkInsertionCompleted().
                _ = try session.insertCannula(optionalAlerts: [], silent: true)

                // 9. Check insertion completed (GetStatus → sim advances to
                //    PodProgressRunningAbove50U → markSetupProgressCompleted)
                try session.checkInsertionCompleted()

                // 10. Wait for the cannula-insertion bolus to finish.
                //
                //     The Go sim sets BolusEnd = now + (pulses * 2s) when ProgramInsulin
                //     is received. For the cannula insertion (0.5U = 10 pulses):
                //       BolusEnd = now + 20s
                //     A GetStatus issued before BolusEnd shows BolusActive=true and
                //     leaves `unfinalizedBolus` set in podState — which makes subsequent
                //     enactBolus calls fail with PodCommsError.unfinalizedBolus.
                //
                //     We poll with GetStatus until `deliveryStatus.bolusing == false`
                //     (or up to ~25s). This adds at most ~20s to pairFreshPod's wall time.
                let bolusFinishDeadline = Date().addingTimeInterval(25)
                while Date() < bolusFinishDeadline {
                    let statusResp = try session.getStatus(noSeqGetStatus: true)
                    if !statusResp.deliveryStatus.bolusing {
                        break
                    }
                    Thread.sleep(forTimeInterval: 1.0)
                }

            } catch {
                setupError = error
            }
        }
        wait(for: [setupExp], timeout: 60.0)
        if let error = setupError {
            XCTFail("Full pod setup failed: \(error)\nstderr: \(self.bridge.stderrTail())", file: file, line: line)
            throw error
        }

        // Verify the pod is now fully active before returning.
        guard manager.hasActivePod else {
            let e = NSError(domain: "T1", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "pairFreshPod: pod not active after setup; setupProgress=\(String(describing: manager.state.podState?.setupProgress))"
            ])
            XCTFail(e.localizedDescription, file: file, line: line)
            throw e
        }

        return manager
    }

    // MARK: - Shared helpers

    /// Build a fresh unpaired OmniBLEPumpManager wired to use the CBM-mock
    /// BluetoothManager (CBMCentralManagerFactory returns the mock under
    /// targetEnvironment(simulator), so OmniBLE's BluetoothManager picks up
    /// our registered MockOmnipodPeripheral automatically).
    ///
    /// Also wires up a MockPumpManagerDelegate so that OmniBLEPumpManager's
    /// store(doses:) path doesn't fatal-error on a nil pumpManagerDelegate.
    func makeFreshPumpManager() -> OmniBLEPumpManager {
        let state = OmniBLEPumpManagerState(
            podState: nil,
            timeZone: .currentFixed,
            basalSchedule: BasalSchedule(entries: [
                BasalScheduleEntry(rate: 1.0, startTime: 0)
            ]),
            insulinType: .novolog,
            maximumTempBasalRate: 5.0
        )
        let manager = OmniBLEPumpManager(state: state)
        let delegate = MockPumpManagerDelegate()
        manager.pumpManagerDelegate = delegate
        self.mockDelegate = delegate // keep alive (manager holds weak ref)
        return manager
    }

    /// Brief settling pause to let CBMCentralManagerMock's per-instance
    /// initialization async dispatch fire on whatever queue OmniBLE's
    /// BluetoothManager passed at init time. 500ms is plenty in practice.
    func waitForBluetoothSettle(timeout: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Helper for diagnostics: dump the current stderr from pod-sim. Call from a failing test.
    func dumpPodSimStderr() {
        let tail = bridge.stderrTail(maxBytes: 8192)
        print("=== pod-sim stderr ===")
        print(tail)
        print("=== end stderr ===")
    }
}
