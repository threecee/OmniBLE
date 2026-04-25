import Foundation
import LoopKit
@testable import OmniBLE

/// Test helper that conforms to OmniBLEPodOwner to record what would have been
/// called against the real BluetoothManager / PodComms paths, without
/// instantiating a real OmniBLEPumpManager (which triggers CBCentralManager
/// creation and requires the bluetooth-central entitlement).
final class MockOmniBLEPumpManager: OmniBLEPodOwner {

    // MARK: - Per-method counters (backward-compatible with existing tests)

    var restoredPodStates: [PodState] = []
    var connectCallCount = 0
    var disconnectCallCount = 0

    // MARK: - Ordered call log (for integration / sequencing tests)

    /// An ordered record of every call made to this mock's OmniBLEPodOwner methods.
    /// Use this to assert that phone→watch→phone round-trips drive the correct
    /// acquire/release sequence on each side.
    enum Call: Equatable {
        /// restorePodState was called; captures the pod's bleIdentifier as a
        /// string proxy (avoids requiring full PodState Equatable conformance).
        case restorePodState(podSerial: String)
        case connectToActivePod
        case disconnectFromActivePod
    }

    private(set) var callLog: [Call] = []

    // MARK: - OmniBLEPodOwner

    func restorePodState(_ podState: PodState) {
        restoredPodStates.append(podState)
        callLog.append(.restorePodState(podSerial: podState.bleIdentifier))
    }

    func connectToActivePod() {
        connectCallCount += 1
        callLog.append(.connectToActivePod)
    }

    func disconnectFromActivePod() {
        disconnectCallCount += 1
        callLog.append(.disconnectFromActivePod)
    }
}
