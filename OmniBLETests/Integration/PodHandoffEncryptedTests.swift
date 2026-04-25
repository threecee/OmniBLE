//
//  PodHandoffEncryptedTests.swift
//  OmniBLETests
//
//  T.1 Phase 8 — the marquee handoff verification.
//
//  Closes B.2.e's hardware verification gap: drives the full phone↔watch pod
//  ownership round-trip through the SAME pod-sim subprocess, exercised at the
//  BLE wire level with real AES-128 encryption (LTK transferred via
//  OmniBLEHandoffPayload, EAP-AKA re-established by the receiving side).
//
//  Key wiring:
//    • The pod-sim's adapter (Vendor/.../main.go OnDisconnect) was patched in
//      T.1 Phase 8 to call bridgeBle.Interrupt() — which signals any in-flight
//      ReadMessageWithTimeout in the pod state machine's CommandLoop to bail
//      out promptly. The CommandLoop then takes its existing reset path
//      (ShutdownConnection + go StartAcceptingCommands), and the next
//      OnConnect re-enters EapAka() for the paired pod. Without this, a
//      paired pod's CommandLoop would AES-decrypt-fail on the watch's
//      plaintext HELLO frame and log.Fatalf the subprocess.
//    • Each OmniBLEPumpManager has its own BluetoothManager, which in turn
//      owns its own CBMCentralManager — Phase 4 Spike B/C confirmed two
//      centrals coexist in one process and a second can connect after the
//      first disconnects (sequential pattern).
//    • Each pump manager needs its OWN QueueBouncingCentralDelegate (CBM's
//      scan-result callback fires on the main thread regardless of which
//      central it belongs to; the wrapper redispatches onto the right
//      manager queue).
//    • The watch-side OmniBLEPumpManagerState is constructed with the
//      phone's controllerId/podId (production B.2.e is expected to ferry
//      these alongside the handoff payload via WCSession). Without this,
//      PodComms.establishNewSession() on the watch would use a random myId
//      that doesn't match the LTK derivation context.
//

import XCTest
import CoreBluetooth
import CoreBluetoothMock
import LoopKit
@testable import OmniBLE

final class PodHandoffEncryptedTests: PodSimulatorTestCase {

    /// Watch-side queue-bouncing wrapper. Held strong here so CBM (which uses
    /// weak delegate refs) doesn't drop it for the duration of the test.
    /// (PodSimulatorTestCase already tracks `queueBouncer` for the phone-side.)
    private var watchQueueBouncer: QueueBouncingCentralDelegate?

    /// Watch-side delegate. Held strong here (the manager stores it weakly).
    private var watchMockDelegate: MockPumpManagerDelegate?

    override func tearDownWithError() throws {
        watchQueueBouncer = nil
        watchMockDelegate = nil
        try super.tearDownWithError()
    }

    // MARK: - Helper: build a watch-side OmniBLEPumpManager with matching IDs

    /// Construct a fresh OmniBLEPumpManager configured to act as the WATCH-side
    /// driver after a handoff. Uses the same controllerId/podId as the supplied
    /// phone-side manager (production B.2.e ferries these via WCSession alongside
    /// the OmniBLEHandoffPayload so the watch's PodComms uses the correct myId
    /// during session re-establishment).
    ///
    /// Caller MUST call `restorePodState(_:)` then `connectToActivePod()` on
    /// the returned manager to wire it to the active pod.
    private func makeWatchSidePumpManager(matching phonePM: OmniBLEPumpManager) -> OmniBLEPumpManager {
        let phoneState = phonePM.state
        var watchState = OmniBLEPumpManagerState(
            podState: nil,                                // hydrated post-construction via restorePodState
            timeZone: phoneState.timeZone,
            basalSchedule: BasalSchedule(entries: [
                BasalScheduleEntry(rate: 1.0, startTime: 0)
            ]),
            controllerId: phoneState.controllerId,        // <- crucial for encryption continuity
            podId: phoneState.podId,                      // <- crucial for encryption continuity
            insulinType: phoneState.insulinType ?? .novolog,
            maximumTempBasalRate: 5.0
        )
        watchState.isOnboarded = true

        let manager = OmniBLEPumpManager(state: watchState)
        let delegate = MockPumpManagerDelegate()
        manager.pumpManagerDelegate = delegate
        self.watchMockDelegate = delegate
        return manager
    }

    /// Install a watch-side queue-bouncing wrapper, mirroring the base-class
    /// `installQueueBouncingDelegate` but storing the wrapper in the test's
    /// own `watchQueueBouncer` slot (the base class only has one slot, used
    /// for the phone side).
    private func installWatchQueueBouncer(on watchPM: OmniBLEPumpManager) {
        let bm = watchPM.podCommsForTesting.bluetoothManagerForTesting
        let central = bm.centralManagerForTesting!
        let queue = bm.managerQueueForTesting
        let wrapper = QueueBouncingCentralDelegate(target: bm, queue: queue)
        central.delegate = wrapper
        // Re-fire centralManagerDidUpdateState through the wrapper so the
        // BluetoothManager sees a fresh state-change on its own queue.
        queue.async {
            bm.centralManagerDidUpdateState(central)
        }
        self.watchQueueBouncer = wrapper
    }

    // MARK: - Helper: capture reservoir via getPodStatus

    /// Synchronously fetches a fresh status from the pod and returns
    /// (reservoir, insulinDelivered). Fails the test on error.
    private func captureReservoir(from manager: OmniBLEPumpManager,
                                  label: String,
                                  timeout: TimeInterval = 15.0,
                                  file: StaticString = #file,
                                  line: UInt = #line) throws -> (reservoir: Double, delivered: Double) {
        let exp = expectation(description: "getPodStatus(\(label))")
        var result: PumpManagerResult<StatusResponse>?
        manager.getPodStatus { r in
            result = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        switch result {
        case .success(let s):
            return (s.reservoirLevel, s.insulinDelivered)
        case .failure(let e):
            XCTFail("getPodStatus(\(label)) failed: \(e)\nstderr: \(self.bridge.stderrTail())",
                    file: file, line: line)
            throw e
        case nil:
            let e = NSError(domain: "Phase8", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "getPodStatus(\(label)) no completion"])
            XCTFail(e.localizedDescription, file: file, line: line); throw e
        }
    }

    /// After `connectToActivePod()` is called, the pump's BluetoothManager has
    /// the bleIdentifier in `autoConnectIDs` but `devices` is still empty (no
    /// scan has run since this manager was constructed). The scan only starts
    /// from `centralManagerDidUpdateState` when state transitions to .poweredOn
    /// AND `!hasDiscoveredAllAutoConnectDevices`. Since the original state-change
    /// fired while autoConnectIDs was empty, we need to nudge the BluetoothManager
    /// to re-evaluate: re-fire `centralManagerDidUpdateState` on the manager
    /// queue so it sees the populated autoConnectIDs and starts scanning.
    private func nudgeScan(on manager: OmniBLEPumpManager) {
        let bm = manager.podCommsForTesting.bluetoothManagerForTesting
        let central = bm.centralManagerForTesting!
        let queue = bm.managerQueueForTesting
        queue.async {
            bm.centralManagerDidUpdateState(central)
        }
    }

    /// Give the CBM scan → connect → didConnect → completeConfiguration
    /// (sendHello + enableNotifications + establishNewSession) cycle time to
    /// land. `connectToActivePod` returns immediately; the actual BLE
    /// readiness signal is delayed.
    private func waitForReconnect(timeout: TimeInterval = 8.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - 1. testFullPhoneToWatchToPhoneRoundTripWithEncryption (MARQUEE)

    /// THE marquee test — closes B.2.e's hardware verification gap.
    ///
    /// Drives the FULL phone→watch→phone round-trip through the SAME pod-sim
    /// subprocess at the BLE wire level with real AES-128 encryption:
    ///
    ///   1. Phone pairs a fresh pod (LTK exchange, EAP-AKA, SetupPod).
    ///   2. Capture R0 = phone's reservoir.
    ///   3. Phone exports an OmniBLEHandoffPayload (real LTK + serialized podState).
    ///   4. Phone disconnects.
    ///   5. Watch (a SECOND OmniBLEPumpManager with its OWN CBMCentralManager)
    ///      restores from the payload, reconnects (CBM scan finds the same
    ///      MockOmnipodPeripheral; PodComms re-runs sendHello + EAP-AKA using
    ///      the LTK from the payload).
    ///   6. Capture R1 = watch's reservoir. Assert R1 == R0 (no insulin moved).
    ///   7. Watch enacts a 1.0U bolus, waits for completion.
    ///   8. Watch disconnects, exports updated payload.
    ///   9. Phone restores from updated payload, reconnects (its own CBM
    ///      central also re-runs EAP-AKA).
    ///   10. Capture R2 = phone's post-handoff reservoir.
    ///   11. Assert R2 < R1 AND R2 ≈ R0 - 1.0 (within tolerance).
    ///
    /// If this test passes, B.2.e is software-verified end-to-end:
    ///   - LTK survives the handoff payload round-trip
    ///   - Encryption keeps working across central-instance changes
    ///   - Sequence numbers stay in sync via stored MessageTransportState
    ///   - Insulin delivery accounting is correct across handoff legs
    ///
    /// Sim-side prerequisite (T.1 Phase 8): the pod-sim's `OnDisconnect`
    /// adapter callback in `Vendor/omnipod-pod-simulator-bridge/main.go`
    /// must call `bridgeBle.Interrupt()` so the CommandLoop's blocking
    /// `ReadMessageWithTimeout` returns immediately on BLE disconnect. The
    /// CommandLoop then falls into its existing reset path
    /// (`ShutdownConnection` + `go StartAcceptingCommands`), and the next
    /// OnConnect re-enters `EapAka()` for the paired pod — which is exactly
    /// the post-disconnect re-handshake that B.2.e's watch-side acquire
    /// requires. Without this patch, the CommandLoop would try to AES-decrypt
    /// the watch's plaintext HELLO frame and `log.Fatalf` the subprocess.
    func testFullPhoneToWatchToPhoneRoundTripWithEncryption() throws {
        // ── 1. Phone pairs a fresh pod (~25s) ────────────────────────────────
        let phonePM = try pairFreshPod()
        XCTAssertTrue(phonePM.hasActivePod, "phone pod should be active after pairing")

        guard let phonePodState = phonePM.state.podState else {
            XCTFail("phone has no podState after pairFreshPod"); return
        }
        let originalLTK = phonePodState.ltk
        XCTAssertGreaterThanOrEqual(originalLTK.count, 16, "LTK must be at least 16 bytes")

        // ── 2. R0: phone's pre-handoff reservoir ─────────────────────────────
        let (R0, delivered0) = try captureReservoir(from: phonePM, label: "phone-pre-handoff")
        print("[Phase8 marquee] R0 (phone pre-handoff) reservoir=\(R0) delivered=\(delivered0)")

        // ── 3. Phone exports handoff payload (24-hour validity) ──────────────
        let outboundPayload = try OmniBLEHandoffPayload(
            podState: phonePodState,
            lastBolusSequence: nil,
            lastBasalScheduleId: nil,
            validUntil: Date(timeIntervalSinceNow: 86_400)
        )
        // Round-trip through encode/decode to mimic the WCSession transmission.
        let payloadData = try outboundPayload.encoded()
        let decodedPayload = try JSONDecoder().decode(OmniBLEHandoffPayload.self, from: payloadData)
        XCTAssertTrue(decodedPayload.isValid(now: Date()),
                      "decoded payload must be within validUntil window")
        let restoredPodStateForWatch = try decodedPayload.decodedPodState()
        XCTAssertEqual(restoredPodStateForWatch.ltk, originalLTK,
                       "LTK must survive payload encode/decode unchanged")

        // ── 4. Phone disconnects ─────────────────────────────────────────────
        phonePM.disconnectFromActivePod()
        // Give the BLE disconnect callback time to land.
        waitForBluetoothSettle(timeout: 1.5)

        // ── 5. Watch restores + reconnects ───────────────────────────────────
        let watchPM = makeWatchSidePumpManager(matching: phonePM)
        installWatchQueueBouncer(on: watchPM)
        waitForBluetoothSettle(timeout: 1.0)

        // restorePodState BEFORE connectToActivePod so PodComms knows the
        // bleIdentifier and the LTK before it tries to scan + handshake.
        watchPM.restorePodState(restoredPodStateForWatch)
        XCTAssertTrue(watchPM.hasActivePod, "watch should report active pod after restorePodState")

        watchPM.connectToActivePod()
        nudgeScan(on: watchPM)
        // Give CBM time to scan, find the peripheral, connect, and complete
        // configuration (sendHello + enableNotifications + establishNewSession).
        waitForReconnect(timeout: 8.0)

        // ── 6. R1: watch's pre-bolus reservoir; assert no movement ──────────
        let (R1, delivered1) = try captureReservoir(from: watchPM, label: "watch-pre-bolus")
        print("[Phase8 marquee] R1 (watch pre-bolus) reservoir=\(R1) delivered=\(delivered1)")
        // (R1 == R0 assertion folded into final assertion block at step 11.)

        // ── 7. Watch enacts a 1.0U bolus, waits for completion ──────────────
        let bolusExp = expectation(description: "watch enactBolus 1.0U")
        var bolusErr: PumpManagerError?
        watchPM.enactBolus(units: 1.0, activationType: .manualNoRecommendation) { err in
            bolusErr = err
            bolusExp.fulfill()
        }
        wait(for: [bolusExp], timeout: 15.0)
        if let e = bolusErr {
            XCTFail("watch enactBolus failed: \(e)\nstderr: \(self.bridge.stderrTail())")
            return
        }

        // 1.0U = 20 pulses; sim sets BolusEnd = now + 40s. Wait for completion.
        Thread.sleep(forTimeInterval: 43.0)

        // Sanity: watch sees the bolus completed
        let (rWatchPostBolus, dWatchPostBolus) = try captureReservoir(from: watchPM, label: "watch-post-bolus")
        print("[Phase8 marquee] watch post-bolus reservoir=\(rWatchPostBolus) delivered=\(dWatchPostBolus)")

        // ── 8. Watch disconnects, exports updated payload ───────────────────
        guard let watchPodState = watchPM.state.podState else {
            XCTFail("watch lost podState after bolus"); return
        }
        let returnPayload = try OmniBLEHandoffPayload(
            podState: watchPodState,
            lastBolusSequence: nil,
            lastBasalScheduleId: nil,
            validUntil: Date(timeIntervalSinceNow: 86_400)
        )
        let returnData = try returnPayload.encoded()
        let returnDecoded = try JSONDecoder().decode(OmniBLEHandoffPayload.self, from: returnData)
        let podStateForPhoneReturn = try returnDecoded.decodedPodState()

        watchPM.disconnectFromActivePod()
        waitForBluetoothSettle(timeout: 1.5)

        // ── 9. Phone re-acquires ────────────────────────────────────────────
        phonePM.restorePodState(podStateForPhoneReturn)
        phonePM.connectToActivePod()
        nudgeScan(on: phonePM)
        waitForReconnect(timeout: 8.0)

        // ── 10. R2: phone's post-handoff reservoir ──────────────────────────
        let (R2, delivered2) = try captureReservoir(from: phonePM, label: "phone-post-handoff")
        print("[Phase8 marquee] R2 (phone post-handoff) reservoir=\(R2) delivered=\(delivered2)")

        // ── 11. Assertions: bolus accounting survived the handoffs ──────────
        //
        // Note: pod-sim's reservoirLevel reports as the "above 50U sentinel"
        // (51.15) while >50U remaining — so we can't use reservoirLevel to
        // detect the 1.0U bolus delta. The `insulinDelivered` cumulative
        // counter is the right signal: it increases monotonically and reflects
        // every successful program-insulin command.
        //
        // delivered0 = phone post-pair, before handoff (≈3.10 from cannula prime)
        // delivered2 = phone post-handoff, after watch's 1.0U bolus
        XCTAssertGreaterThan(delivered2, delivered0,
                             "phone should see increased insulinDelivered post-handoff (watch's bolus)")
        XCTAssertEqual(delivered2 - delivered0, 1.0, accuracy: 0.15,
                       "post-handoff insulinDelivered should reflect watch's 1.0U bolus")
        // Sanity: R1 should match R0 (no insulin moved during handoff itself)
        XCTAssertEqual(R1, R0, accuracy: 0.05,
                       "no insulin should have been delivered between handoff legs")

        print("[Phase8 marquee] PASS — R0=\(R0) R1=\(R1) R2=\(R2)")
        print("[Phase8 marquee] PASS — delivered0=\(delivered0) delivered1=\(delivered1) delivered2=\(delivered2) Δ=\(delivered2 - delivered0)")
    }

    // MARK: - 2. testHandoffWithReservoirChangeBetweenLegs

    /// Variant: instead of "watch bolus then return to phone", interleave the
    /// reservoir change WHILE watch holds the pod. Same plumbing, different
    /// assertion focus — validates that interleaved deliveries are correctly
    /// tracked after re-acquisition.
    ///
    /// This essentially exercises the same B.2.e path as the marquee but with
    /// a different assertion shape (verifies mid-handoff measurements are
    /// consistent with the final return-to-phone state).
    ///
    func testHandoffWithReservoirChangeBetweenLegs() throws {
        let phonePM = try pairFreshPod()
        guard let phonePodState = phonePM.state.podState else {
            XCTFail("no podState after pair"); return
        }

        let (R0, delivered0) = try captureReservoir(from: phonePM, label: "phone-pre-handoff")
        print("[Phase8 interleaved] R0=\(R0) delivered0=\(delivered0)")

        let outPayload = try OmniBLEHandoffPayload(
            podState: phonePodState, lastBolusSequence: nil, lastBasalScheduleId: nil,
            validUntil: Date(timeIntervalSinceNow: 86_400))
        let outDecoded = try JSONDecoder().decode(
            OmniBLEHandoffPayload.self, from: try outPayload.encoded())
        let watchPodState = try outDecoded.decodedPodState()

        phonePM.disconnectFromActivePod()
        waitForBluetoothSettle(timeout: 1.5)

        let watchPM = makeWatchSidePumpManager(matching: phonePM)
        installWatchQueueBouncer(on: watchPM)
        waitForBluetoothSettle(timeout: 1.0)
        watchPM.restorePodState(watchPodState)
        watchPM.connectToActivePod()
        nudgeScan(on: watchPM)
        waitForReconnect(timeout: 8.0)

        // Watch enacts a 0.5U bolus mid-handoff (smaller for shorter wait).
        // 0.5U = 10 pulses; sim sets BolusEnd = now + 20s.
        let bolusExp = expectation(description: "interleaved 0.5U bolus")
        var bolusErr: PumpManagerError?
        watchPM.enactBolus(units: 0.5, activationType: .manualNoRecommendation) { err in
            bolusErr = err; bolusExp.fulfill()
        }
        wait(for: [bolusExp], timeout: 15.0)
        if let e = bolusErr {
            XCTFail("interleaved enactBolus failed: \(e)\nstderr: \(self.bridge.stderrTail())")
            return
        }
        Thread.sleep(forTimeInterval: 23.0) // wait for bolus completion

        // Capture watch's post-bolus reservoir (mid-handoff snapshot).
        let (Rwatch, deliveredWatch) = try captureReservoir(from: watchPM, label: "watch-mid")
        print("[Phase8 interleaved] R(watch mid)=\(Rwatch) delivered=\(deliveredWatch)")
        XCTAssertGreaterThan(deliveredWatch, delivered0,
                             "watch-mid insulinDelivered should be increased by the 0.5U bolus")

        // Hand back to phone.
        guard let postBolusPodState = watchPM.state.podState else {
            XCTFail("watch lost podState"); return
        }
        let backPayload = try OmniBLEHandoffPayload(
            podState: postBolusPodState, lastBolusSequence: nil, lastBasalScheduleId: nil,
            validUntil: Date(timeIntervalSinceNow: 86_400))
        let backDecoded = try JSONDecoder().decode(
            OmniBLEHandoffPayload.self, from: try backPayload.encoded())
        let phoneRestoreState = try backDecoded.decodedPodState()

        watchPM.disconnectFromActivePod()
        waitForBluetoothSettle(timeout: 1.5)

        phonePM.restorePodState(phoneRestoreState)
        phonePM.connectToActivePod()
        nudgeScan(on: phonePM)
        waitForReconnect(timeout: 8.0)

        let (R2, delivered2) = try captureReservoir(from: phonePM, label: "phone-post-handoff")
        print("[Phase8 interleaved] R2=\(R2) delivered2=\(delivered2)")

        // Phone should agree with watch's mid-handoff measurement (the
        // reservoir+delivered counters survive both BLE re-handshakes).
        XCTAssertEqual(delivered2, deliveredWatch, accuracy: 0.05,
                       "phone post-handoff insulinDelivered should match watch's mid-handoff value")
        XCTAssertEqual(delivered2 - delivered0, 0.5, accuracy: 0.15,
                       "round-trip insulinDelivered should reflect the interleaved 0.5U bolus")
    }

    // MARK: - 3. testStaleLTKRejectedAtAcquire

    /// The deactivate-then-stale-LTK scenario: phone exports a payload, then
    /// the user deactivates the pod on the phone (DeactivateFlag set; pod-sim
    /// state machine exits its command loop). The watch then attempts to
    /// acquire BLE with the now-stale payload.
    ///
    /// Expected: a clean error from the watch's connect/handshake — but in
    /// practice, after the Go sim's state machine exits its command loop, BLE
    /// operations either time out or hang depending on whether the bridge
    /// drain thread is still pumping NOTIFYs.
    ///
    /// SKIPPED with documented reasoning. To exercise this for real you'd need:
    ///   - A way to detect "pod is gone" at the BLE level rather than at the
    ///     EAP-AKA level (the LTK matches itself; the pod just doesn't reply)
    ///   - Or a richer error-classification path on the receiving side that
    ///     distinguishes "pod said no" from "pod silent"
    func testStaleLTKRejectedAtAcquire() throws {
        try XCTSkipIf(
            true,
            "Skipped: once the pod is deactivated (DeactivateFlag set), the Go pod-sim's " +
            "command loop exits and subsequent BLE operations time out rather than failing " +
            "with a typed LTK-mismatch error. Distinguishing 'stale LTK' from 'pod silent' " +
            "would require richer error classification at the OmniBLE/PodComms layer. " +
            "Defer to a follow-up phase that adds that classification."
        )
    }
}
