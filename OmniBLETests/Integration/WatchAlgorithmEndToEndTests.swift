//
//  WatchAlgorithmEndToEndTests.swift
//  OmniBLETests
//
//  B.6 Phase 4b — load-bearing integration test for the watch closed loop.
//
//  Proves the watch CAN close the loop end-to-end against a real (encrypted,
//  BLE) emulated pod by driving:
//
//    1. Phone-side fresh-pod pairing (LTK exchange + EAP-AKA + SetupPod via
//       the Go pod-sim subprocess at the BLE wire level).
//    2. Watch-side OmniBLEPumpManager constructed with matching controllerId/
//       podId (mirrors the production B.2.e ferry of these alongside the
//       OmniBLEHandoffPayload over WCSession).
//    3. Watch-side restorePodState + connectToActivePod so the second
//       CBMCentralManager re-runs sendHello + EAP-AKA against the same pod.
//    4. Construction of WatchAlgorithmDriver (from the new WatchAlgorithmKit
//       multi-platform framework) wired to the watch-side OmniBLEPumpManager,
//       with canned rising-glucose stores and warmup override = false so the
//       didRecommend gate (gate 1) doesn't suppress.
//    5. Calling driver.underlyingRunner.loop() to trigger one iteration.
//    6. Polling for either a temp basal install (`.tempBasal` in
//       basalDeliveryState) or a bolus (insulinDelivered counter increase) on
//       the emulated pod.
//
//  Closes the integration verification gap from B.4's audit. Made possible by
//  Loop commit c0be4514 (Phase 4a-bis) which extracted WatchAlgorithmDriver
//  into the new WatchAlgorithmKit multi-platform framework so the same source
//  runs in:
//    - watchOS production (WatchApp Extension links WatchAlgorithmKit)
//    - iOS Simulator integration test (this file links WatchAlgorithmKit)
//

import XCTest
import CoreBluetooth
import CoreBluetoothMock
import HealthKit
import LoopKit
import LoopAlgorithmCore
import LoopCore
@testable import OmniBLE
@testable import WatchAlgorithmKit

final class WatchAlgorithmEndToEndTests: PodSimulatorTestCase {

    /// Watch-side queue-bouncing wrapper. Held strong here so CBM (which uses
    /// weak delegate refs) doesn't drop it for the duration of the test.
    private var watchQueueBouncer: QueueBouncingCentralDelegate?

    /// Watch-side delegate. Held strong here (the manager stores it weakly).
    private var watchMockDelegate: MockPumpManagerDelegate?

    /// Watch-side pump manager. Held strong here so the CBMCentralManager and
    /// associated state survive across the wait windows.
    private var watchPM: OmniBLEPumpManager?

    /// Driver under test. Held strong so the underlying LoopAlgorithmRunner
    /// finishes its async dispatch onto the dataAccessQueue before tearDown.
    private var driver: WatchAlgorithmDriver?

    override func tearDownWithError() throws {
        driver = nil
        watchPM = nil
        watchQueueBouncer = nil
        watchMockDelegate = nil
        try super.tearDownWithError()
    }

    // MARK: - Helper: build a watch-side OmniBLEPumpManager with matching IDs
    // (verbatim from PodHandoffEncryptedTests.swift)

    private func makeWatchSidePumpManager(matching phonePM: OmniBLEPumpManager) -> OmniBLEPumpManager {
        let phoneState = phonePM.state
        var watchState = OmniBLEPumpManagerState(
            podState: nil,
            timeZone: phoneState.timeZone,
            basalSchedule: BasalSchedule(entries: [
                BasalScheduleEntry(rate: 1.0, startTime: 0)
            ]),
            controllerId: phoneState.controllerId,
            podId: phoneState.podId,
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

    private func installWatchQueueBouncer(on watchPM: OmniBLEPumpManager) {
        let bm = watchPM.podCommsForTesting.bluetoothManagerForTesting
        let central = bm.centralManagerForTesting!
        let queue = bm.managerQueueForTesting
        let wrapper = QueueBouncingCentralDelegate(target: bm, queue: queue)
        central.delegate = wrapper
        queue.async {
            bm.centralManagerDidUpdateState(central)
        }
        self.watchQueueBouncer = wrapper
    }

    // MARK: - Helper: wait for BLE reconnect (mirrors PodHandoffEncryptedTests)

    private func waitForReconnect(timeout: TimeInterval = 8.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - Helper: capture insulinDelivered

    private func captureInsulinDelivered(from manager: OmniBLEPumpManager,
                                         label: String,
                                         timeout: TimeInterval = 15.0) throws -> Double {
        let exp = expectation(description: "getPodStatus(\(label))")
        var result: PumpManagerResult<StatusResponse>?
        manager.getPodStatus { r in
            result = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        switch result {
        case .success(let s):
            return s.insulinDelivered
        case .failure(let e):
            XCTFail("getPodStatus(\(label)) failed: \(e)\nstderr: \(self.bridge.stderrTail())")
            throw e
        case nil:
            let e = NSError(domain: "WatchAlgorithmEndToEndTests", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "getPodStatus(\(label)) no completion"])
            XCTFail(e.localizedDescription)
            throw e
        }
    }

    // MARK: - Inline minimal mock stores
    //
    // Each store implements the protocol surface required by
    // LoopAlgorithmRunner during a single iteration. They are intentionally
    // minimal — empty COB, empty IOB, single rising-glucose history — so the
    // algorithm has unambiguous "high-and-rising, no insulin on board, no
    // carbs, target=100-120" inputs that should produce a positive temp
    // basal recommendation.

    private final class TestGlucoseStore: GlucoseStoreProtocol {
        var samples: [StoredGlucoseSample] = []

        var latestGlucose: GlucoseSampleValue? { samples.last }
        var delegate: GlucoseStoreDelegate?
        var managedDataInterval: TimeInterval?

        func addGlucoseSamples(_ samples: [NewGlucoseSample], completion: @escaping (Swift.Result<[StoredGlucoseSample], Error>) -> Void) {
            completion(.success([]))
        }

        func getGlucoseSamples(start: Date?, end: Date?, completion: @escaping (Swift.Result<[StoredGlucoseSample], Error>) -> Void) {
            let filtered = samples.filter { sample in
                if let start, sample.startDate < start { return false }
                if let end, sample.startDate > end { return false }
                return true
            }
            completion(.success(filtered))
        }

        func generateDiagnosticReport(_ completion: @escaping (String) -> Void) {
            completion("")
        }

        func purgeAllGlucoseSamples(healthKitPredicate: NSPredicate, completion: @escaping (Error?) -> Void) {
            completion(nil)
        }

        func executeGlucoseQuery(fromQueryAnchor queryAnchor: GlucoseStore.QueryAnchor?, limit: Int, completion: @escaping (GlucoseStore.GlucoseQueryResult) -> Void) {
            completion(.success(GlucoseStore.QueryAnchor(), []))
        }

        func getRecentMomentumEffect(for date: Date?, _ completion: @escaping (Swift.Result<[GlucoseEffect], Error>) -> Void) {
            // Compute momentum directly from the canned samples — the algorithm
            // uses this to produce a rising prediction.
            let now = date ?? Date()
            let recent = samples.filter { $0.startDate >= now.addingTimeInterval(-GlucoseMath.momentumDataInterval) }
            completion(.success(recent.linearMomentumEffect()))
        }

        func getCounteractionEffects(start: Date, end: Date?, to effects: [GlucoseEffect], _ completion: @escaping (Swift.Result<[GlucoseEffectVelocity], Error>) -> Void) {
            let filtered = samples.filter { sample in
                if sample.startDate < start { return false }
                if let end, sample.startDate > end { return false }
                return true
            }
            completion(.success(filtered.counteractionEffects(to: effects)))
        }

        func counteractionEffects<Sample>(for samples: [Sample], to effects: [GlucoseEffect]) -> [GlucoseEffectVelocity] where Sample : GlucoseSampleValue {
            samples.counteractionEffects(to: effects)
        }
    }

    private final class TestCarbStore: CarbStoreProtocol {
        var preferredUnit: HKUnit! = .gram()
        var delegate: CarbStoreDelegate?
        var carbRatioSchedule: CarbRatioSchedule?
        var insulinSensitivitySchedule: InsulinSensitivitySchedule?
        var insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule?
        var carbRatioScheduleApplyingOverrideHistory: CarbRatioSchedule?
        var maximumAbsorptionTimeInterval: TimeInterval { defaultAbsorptionTimes.slow * 2 }
        var delta: TimeInterval = .minutes(5)
        var defaultAbsorptionTimes: CarbStore.DefaultAbsorptionTimes = (
            fast: .minutes(30), medium: .hours(3), slow: .hours(5)
        )

        func replaceCarbEntry(_ oldEntry: StoredCarbEntry, withEntry newEntry: NewCarbEntry, completion: @escaping (CarbStoreResult<StoredCarbEntry>) -> Void) {
            completion(.failure(.notConfigured))
        }
        func addCarbEntry(_ entry: NewCarbEntry, completion: @escaping (CarbStoreResult<StoredCarbEntry>) -> Void) {
            completion(.failure(.notConfigured))
        }
        func getCarbStatus(start: Date, end: Date?, effectVelocities: [GlucoseEffectVelocity]?, completion: @escaping (CarbStoreResult<[CarbStatus<StoredCarbEntry>]>) -> Void) {
            completion(.success([]))
        }
        func generateDiagnosticReport(_ completion: @escaping (String) -> Void) {
            completion("")
        }
        func getGlucoseEffects(start: Date, end: Date?, effectVelocities: [GlucoseEffectVelocity], completion: @escaping (CarbStoreResult<(entries: [StoredCarbEntry], effects: [GlucoseEffect])>) -> Void) {
            completion(.success(([], [])))
        }
        func glucoseEffects<Sample>(of samples: [Sample], startingAt start: Date, endingAt end: Date?, effectVelocities: [GlucoseEffectVelocity]) throws -> [GlucoseEffect] where Sample : CarbEntry {
            return []
        }
        func getCarbsOnBoardValues(start: Date, end: Date?, effectVelocities: [GlucoseEffectVelocity]?, completion: @escaping (CarbStoreResult<[CarbValue]>) -> Void) {
            completion(.success([]))
        }
        func carbsOnBoard(at date: Date, effectVelocities: [GlucoseEffectVelocity]?, completion: @escaping (CarbStoreResult<CarbValue>) -> Void) {
            completion(.failure(.notConfigured))
        }
        func getTotalCarbs(since start: Date, completion: @escaping (CarbStoreResult<CarbValue>) -> Void) {
            completion(.failure(.notConfigured))
        }
        func deleteCarbEntry(_ entry: StoredCarbEntry, completion: @escaping (CarbStoreResult<Bool>) -> Void) {
            completion(.failure(.notConfigured))
        }
    }

    private final class TestDoseStore: DoseStoreProtocol {
        var basalProfile: BasalRateSchedule?
        var insulinModelProvider: InsulinModelProvider = PresetInsulinModelProvider(defaultRapidActingModel: nil)
        var longestEffectDuration: TimeInterval = .hours(6)
        var insulinSensitivitySchedule: InsulinSensitivitySchedule?
        var basalProfileApplyingOverrideHistory: BasalRateSchedule? { basalProfile }
        var lastReservoirValue: ReservoirValue?
        var lastAddedPumpData: Date = Date()
        var delegate: DoseStoreDelegate?
        var device: HKDevice?
        var pumpRecordsBasalProfileStartEvents: Bool = false
        var pumpEventQueryAfterDate: Date = Date()

        func addPumpEvents(_ events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, completion: @escaping (DoseStore.DoseStoreError?) -> Void) {
            completion(nil)
        }
        func addReservoirValue(_ unitVolume: Double, at date: Date, completion: @escaping (ReservoirValue?, ReservoirValue?, Bool, DoseStore.DoseStoreError?) -> Void) {
            completion(nil, nil, false, nil)
        }
        func getNormalizedDoseEntries(start: Date, end: Date?, completion: @escaping (DoseStoreResult<[DoseEntry]>) -> Void) {
            completion(.success([]))
        }
        func executePumpEventQuery(fromQueryAnchor queryAnchor: DoseStore.QueryAnchor?, limit: Int, completion: @escaping (DoseStore.PumpEventQueryResult) -> Void) {
            completion(.success(DoseStore.QueryAnchor(), []))
        }
        func generateDiagnosticReport(_ completion: @escaping (String) -> Void) {
            completion("")
        }
        func addDoses(_ doses: [DoseEntry], from device: HKDevice?, completion: @escaping (Error?) -> Void) {
            completion(nil)
        }
        func insulinOnBoard(at date: Date, completion: @escaping (DoseStoreResult<InsulinValue>) -> Void) {
            completion(.success(InsulinValue(startDate: date, value: 0)))
        }
        func getGlucoseEffects(start: Date, end: Date?, basalDosingEnd: Date?, completion: @escaping (DoseStoreResult<[GlucoseEffect]>) -> Void) {
            completion(.success([]))
        }
        func getInsulinOnBoardValues(start: Date, end: Date?, basalDosingEnd: Date?, completion: @escaping (DoseStoreResult<[InsulinValue]>) -> Void) {
            completion(.success([]))
        }
        func getTotalUnitsDelivered(since startDate: Date, completion: @escaping (DoseStoreResult<InsulinValue>) -> Void) {
            completion(.success(InsulinValue(startDate: startDate, value: 0)))
        }
    }

    private final class TestDosingDecisionStore: DosingDecisionStoreProtocol {
        var storedDecisions: [StoredDosingDecision] = []
        func storeDosingDecision(_ dosingDecision: StoredDosingDecision, completion: @escaping () -> Void) {
            storedDecisions.append(dosingDecision)
            completion()
        }
    }

    // MARK: - Helpers: build canned algorithm inputs

    /// Build a glucose store with 7 samples over the past 30 minutes rising
    /// from 150 → 250 mg/dL — well above the 100-120 target with a strong
    /// upward slope (~3.3 mg/dL/min). With 0 IOB and 0 COB, this should
    /// trigger the algorithm to recommend a positive temp basal (or bolus).
    private func makeRisingGlucoseStore(now: Date) -> TestGlucoseStore {
        let store = TestGlucoseStore()
        // 7 samples at 5-minute intervals: t-30, t-25, ..., t-0.
        // 150 → 250 over 30 minutes ≈ 3.3 mg/dL/min trend.
        // Avoid ambiguity: OmniBLE and LoopCore both add static
        // .milligramsPerDeciliter to HKUnit. Build the unit from string.
        let mgdL = HKUnit(from: "mg/dL")
        let mgdLPerMin = mgdL.unitDivided(by: HKUnit(from: "min"))
        for i in 0..<7 {
            let mgdl = 150.0 + Double(i) * (100.0 / 6.0)  // 150, 166.67, 183.33, ..., 250
            let date = now.addingTimeInterval(-Double(30 - i * 5) * 60)
            let q = HKQuantity(unit: mgdL, doubleValue: mgdl)
            store.samples.append(StoredGlucoseSample(
                uuid: UUID(),
                provenanceIdentifier: "WatchAlgorithmEndToEndTests",
                syncIdentifier: "watch-test-\(i)",
                syncVersion: 1,
                startDate: date,
                quantity: q,
                condition: nil,
                trend: .upUpUp,
                trendRate: HKQuantity(unit: mgdLPerMin, doubleValue: 3.3),
                isDisplayOnly: false,
                wasUserEntered: false,
                device: nil,
                healthKitEligibleDate: nil
            ))
        }
        return store
    }

    private func makeMinimalLoopSettings() -> LoopSettings {
        // Avoid ambiguity: OmniBLE and LoopCore both add static
        // .milligramsPerDeciliter to HKUnit. Build the unit from string.
        let mgdL = HKUnit(from: "mg/dL")
        var settings = LoopSettings()
        settings.basalRateSchedule = BasalRateSchedule(
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)],
            timeZone: .current
        )
        settings.insulinSensitivitySchedule = InsulinSensitivitySchedule(
            unit: mgdL,
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            timeZone: .current
        )
        settings.carbRatioSchedule = CarbRatioSchedule(
            unit: .gram(),
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
            timeZone: .current
        )
        settings.glucoseTargetRangeSchedule = GlucoseRangeSchedule(
            unit: mgdL,
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))],
            timeZone: .current
        )
        settings.maximumBolus = 10
        settings.maximumBasalRatePerHour = 4
        // Suspend threshold required for some algorithm paths to function
        settings.suspendThreshold = GlucoseThreshold(unit: mgdL, value: 70)
        // Default to closed-loop (algorithm dose-enaction path)
        settings.dosingEnabled = true
        return settings
    }

    // MARK: - Test

    /// THE marquee Phase 4b test — proves the full chain works:
    /// pod paired → handoff to watch → algorithm runs on watch → didRecommend
    /// gate passes → dose dispatched to emulated pod → pod's insulinDelivered
    /// counter increases (or basalDeliveryState shows .tempBasal).
    func testFullChain_algorithmRunsAndDoseEnactsOnEmulatedPod() throws {
        // ── 1. Phone pairs a fresh pod (~25s) ────────────────────────────────
        let phonePM = try pairFreshPod()
        XCTAssertTrue(phonePM.hasActivePod, "phone pod should be active after pairing")

        guard let phonePodState = phonePM.state.podState else {
            XCTFail("phone has no podState after pairFreshPod"); return
        }

        // ── 2. Phone exports handoff payload, then disconnects ──────────────
        let outboundPayload = try OmniBLEHandoffPayload(
            podState: phonePodState,
            lastBolusSequence: nil,
            lastBasalScheduleId: nil,
            validUntil: Date(timeIntervalSinceNow: 86_400)
        )
        let restoredPodState = try outboundPayload.decodedPodState()
        phonePM.disconnectFromActivePod()
        waitForBluetoothSettle(timeout: 1.5)

        // ── 3. Watch-side OmniBLEPumpManager + restore + reconnect ──────────
        let watchPM = makeWatchSidePumpManager(matching: phonePM)
        self.watchPM = watchPM
        installWatchQueueBouncer(on: watchPM)
        waitForBluetoothSettle(timeout: 1.0)

        watchPM.restorePodState(restoredPodState)
        XCTAssertTrue(watchPM.hasActivePod, "watch should report active pod after restorePodState")

        watchPM.connectToActivePod()
        waitForReconnect(timeout: 8.0)

        // ── 4. Capture before-delivered baseline ─────────────────────────────
        let beforeDelivered = try captureInsulinDelivered(from: watchPM, label: "before")
        print("[B6 Phase4b] before insulinDelivered = \(beforeDelivered)")

        // ── 5. Build WatchAlgorithmDriver against canned inputs + watch PM ───
        let now = Date()
        let glucoseStore = makeRisingGlucoseStore(now: now)
        let loopSettings = makeMinimalLoopSettings()
        let snapshot = WatchSettingsSnapshot(
            loopSettings: loopSettings,
            storedSettings: StoredSettings(),
            nightscoutConfig: nil,
            automaticDosingEnabled: true,         // Gate 2 must pass
            isAutomaticDosingAllowed: true        // Gate 3 must pass
        )
        // The runner reads basalProfile / insulinSensitivitySchedule from
        // doseStore (not from settings) when computing dose recommendations,
        // and fails with configurationError if they are nil. Populate the
        // mock store so that production-style schedule access works.
        let doseStore = TestDoseStore()
        doseStore.basalProfile = loopSettings.basalRateSchedule
        doseStore.insulinSensitivitySchedule = loopSettings.insulinSensitivitySchedule
        // Carb store also reads schedule fields when carb-on-board curves
        // touch any glucose effect — mirror dose store population.
        let carbStore = TestCarbStore()
        carbStore.carbRatioSchedule = loopSettings.carbRatioSchedule
        carbStore.insulinSensitivitySchedule = loopSettings.insulinSensitivitySchedule
        carbStore.carbRatioScheduleApplyingOverrideHistory = loopSettings.carbRatioSchedule
        carbStore.insulinSensitivityScheduleApplyingOverrideHistory = loopSettings.insulinSensitivitySchedule

        let driver = WatchAlgorithmDriver(
            carbStore: carbStore,
            doseStore: doseStore,
            glucoseStore: glucoseStore,
            dosingDecisionStore: TestDosingDecisionStore(),
            settingsSnapshot: snapshot,
            now: { now },
            pumpManager: watchPM,                  // Gate 4 must pass (non-nil)
            isWarmingUpOverride: false             // Gate 1 must pass (not warming up)
        )
        self.driver = driver

        // ── 6. Trigger one loop iteration ───────────────────────────────────
        driver.underlyingRunner.loop()

        // ── 7. Poll for outcome (basalDeliveryState .tempBasal OR delta) ────
        let pollDeadline = Date().addingTimeInterval(60.0)
        var afterDelivered = beforeDelivered
        var sawTempBasal = false
        var lastBasalDeliveryState = watchPM.status.basalDeliveryState
        while Date() < pollDeadline {
            // Pump some run-loop time so async callbacks complete.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if case .tempBasal = watchPM.status.basalDeliveryState {
                sawTempBasal = true
                lastBasalDeliveryState = watchPM.status.basalDeliveryState
                break
            }
            afterDelivered = (try? captureInsulinDelivered(from: watchPM, label: "after")) ?? beforeDelivered
            if afterDelivered > beforeDelivered + 0.04 {
                // 0.04U threshold: pod-sim records pulses in 0.05U increments;
                // any single pulse from a bolus or basal trim exceeds this.
                break
            }
            lastBasalDeliveryState = watchPM.status.basalDeliveryState
        }
        print("[B6 Phase4b] after insulinDelivered = \(afterDelivered)")
        print("[B6 Phase4b] sawTempBasal = \(sawTempBasal)")
        print("[B6 Phase4b] last basalDeliveryState = \(String(describing: lastBasalDeliveryState))")

        if !sawTempBasal {
            XCTAssertGreaterThan(
                afterDelivered, beforeDelivered,
                """
                Expected either a temp basal program (basalDeliveryState .tempBasal) \
                or a bolus (insulinDelivered increase), got neither. \
                Algorithm may not have produced a recommendation, or dose-enactment \
                path is broken. lastBasalDeliveryState=\(String(describing: lastBasalDeliveryState))
                """
            )
        }
    }
}
