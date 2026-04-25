//
//  QueueBouncingCentralDelegate.swift
//  OmniBLETests
//
//  Workaround for a CoreBluetoothMock library limitation: its scan-result
//  notify path (`CBMCentralManagerMock.notify(_:for:)`) calls the central's
//  delegate **synchronously from a main-thread NSTimer**, regardless of the
//  per-manager dispatch queue passed at init time.
//
//  OmniBLE's production `BluetoothManager` enforces
//  `dispatchPrecondition(condition: .onQueue(managerQueue))` on every
//  CBMCentralManagerDelegate callback. Receiving a callback on the main
//  thread instead of the managerQueue causes `_dispatch_assert_queue_fail`,
//  which crashes the test process.
//
//  This wrapper sits between the CBM mock and OmniBLE's BluetoothManager:
//    - Registered as the CBM central's delegate
//    - Asynchronously redispatches every callback onto the OmniBLE
//      managerQueue before forwarding to the BluetoothManager's
//      CBMCentralManagerDelegate methods
//
//  Use via `installQueueBouncingDelegate(on:)` from PodSimulatorTestCase
//  after constructing OmniBLEPumpManager.
//
//  T.1 Phase 5b — option (a) of the spec Q1 fallbacks (queue-bouncing wrapper).
//

import Foundation
import CoreBluetooth
import CoreBluetoothMock
@testable import OmniBLE

final class QueueBouncingCentralDelegate: NSObject, CBMCentralManagerDelegate {

    /// The real production delegate (OmniBLE's BluetoothManager). Held
    /// strongly so it doesn't get released while the wrapper is the
    /// CBM central's delegate (CBM uses weak delegate references).
    private let target: CBMCentralManagerDelegate

    /// The queue OmniBLE expects callbacks on.
    private let queue: DispatchQueue

    init(target: CBMCentralManagerDelegate, queue: DispatchQueue) {
        self.target = target
        self.queue = queue
    }

    // MARK: - CBMCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBMCentralManager) {
        let target = self.target
        queue.async {
            target.centralManagerDidUpdateState(central)
        }
    }

    func centralManager(_ central: CBMCentralManager,
                        willRestoreState dict: [String: Any]) {
        let target = self.target
        queue.async {
            target.centralManager(central, willRestoreState: dict)
        }
    }

    func centralManager(_ central: CBMCentralManager,
                        didDiscover peripheral: CBMPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let target = self.target
        queue.async {
            target.centralManager(central,
                                   didDiscover: peripheral,
                                   advertisementData: advertisementData,
                                   rssi: RSSI)
        }
    }

    func centralManager(_ central: CBMCentralManager, didConnect peripheral: CBMPeripheral) {
        let target = self.target
        queue.async {
            target.centralManager(central, didConnect: peripheral)
        }
    }

    func centralManager(_ central: CBMCentralManager,
                        didDisconnectPeripheral peripheral: CBMPeripheral,
                        error: Error?) {
        let target = self.target
        queue.async {
            target.centralManager(central,
                                   didDisconnectPeripheral: peripheral,
                                   error: error)
        }
    }

    func centralManager(_ central: CBMCentralManager,
                        didFailToConnect peripheral: CBMPeripheral,
                        error: Error?) {
        let target = self.target
        queue.async {
            target.centralManager(central,
                                   didFailToConnect: peripheral,
                                   error: error)
        }
    }
}

// MARK: - Test-side installer

extension PodSimulatorTestCase {

    /// Installs a queue-bouncing delegate wrapper on the BluetoothManager's
    /// CBMCentralManager. Must be called AFTER `OmniBLEPumpManager` is
    /// constructed, because that's when the BluetoothManager (and its
    /// CBMCentralManager) come into existence. Returns the wrapper, which
    /// the caller must hold until the test ends — CBM uses weak delegate
    /// refs and would otherwise drop it.
    @discardableResult
    func installQueueBouncingDelegate(on pumpManager: OmniBLEPumpManager) -> QueueBouncingCentralDelegate {
        let bluetoothManager = pumpManager.podCommsForTesting.bluetoothManagerForTesting
        let central = bluetoothManager.centralManagerForTesting!
        let queue = bluetoothManager.managerQueueForTesting
        let wrapper = QueueBouncingCentralDelegate(target: bluetoothManager, queue: queue)
        central.delegate = wrapper

        // Re-fire the centralManagerDidUpdateState callback through the
        // wrapper, since by the time we install the wrapper the CBM central
        // has already fired its initial state-change callback (which went to
        // the original delegate WITHOUT being queue-bounced — though it might
        // not have hit a precondition yet because state==.unknown at init).
        // This ensures BluetoothManager sees a fresh state-change with the
        // wrapper installed and starts processing on the right queue.
        queue.async {
            bluetoothManager.centralManagerDidUpdateState(central)
        }

        return wrapper
    }
}
