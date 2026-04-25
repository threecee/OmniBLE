import Foundation
import LoopKit
@testable import OmniBLE

/// Test helper that conforms to OmniBLEPodOwner to record what would have been
/// called against the real BluetoothManager / PodComms paths, without
/// instantiating a real OmniBLEPumpManager (which triggers CBCentralManager
/// creation and requires the bluetooth-central entitlement).
final class MockOmniBLEPumpManager: OmniBLEPodOwner {
    var restoredPodStates: [PodState] = []
    var connectCallCount = 0
    var disconnectCallCount = 0

    func restorePodState(_ podState: PodState) {
        restoredPodStates.append(podState)
    }

    func connectToActivePod() {
        connectCallCount += 1
    }

    func disconnectFromActivePod() {
        disconnectCallCount += 1
    }
}
