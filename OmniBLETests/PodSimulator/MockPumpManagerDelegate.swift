//
//  MockPumpManagerDelegate.swift
//  OmniBLETests
//
//  Minimal stub PumpManagerDelegate for Phase 6 integration tests.
//  All methods are no-ops or call completions with nil/success so that
//  OmniBLEPumpManager's store(doses:) path doesn't fatal-error when
//  pumpManagerDelegate is nil.
//

import Foundation
import LoopKit
@testable import OmniBLE

final class MockPumpManagerDelegate: NSObject, PumpManagerDelegate {

    // MARK: - PumpManagerStatusObserver

    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {}

    // MARK: - PumpManagerDelegate

    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {}

    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool { return false }

    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {}

    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) {}

    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {}

    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {}

    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, completion: @escaping (Error?) -> Void) {
        // Accept all pump events without error.
        completion(nil)
    }

    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>) -> Void) {
        // No-op; we don't store reservoir values in tests.
    }

    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {}

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {}

    func pumpManager(_ pumpManager: PumpManager, didRequestBasalRateScheduleChange basalRateSchedule: BasalRateSchedule, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date {
        return Date(timeIntervalSinceNow: -60 * 60 * 24) // 24 hours ago
    }

    var detectedSystemTimeOffset: TimeInterval { return 0 }

    var automaticDosingEnabled: Bool { return false }

    // MARK: - DeviceManagerDelegate

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        completion?(nil)
    }

    // MARK: - AlertIssuer

    func issueAlert(_ alert: Alert) {}

    func retractAlert(identifier: Alert.Identifier) {}

    // MARK: - PersistedAlertStore

    func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func doesIssuedAlertExist(identifier: Alert.Identifier, completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Result<[PersistedAlert], Error>) -> Void) {
        completion(.success([]))
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Result<[PersistedAlert], Error>) -> Void) {
        completion(.success([]))
    }

    func recordRetractedAlert(_ alert: Alert, at date: Date) {}
}
