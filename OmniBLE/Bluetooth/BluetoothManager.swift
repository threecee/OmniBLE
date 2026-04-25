//
//  BluetoothManager.swift
//  OmniBLE
//
//  Created by Randall Knutson on 10/10/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import CoreBluetoothMock
import Foundation
import LoopKit
import os.log

public enum BluetoothManagerError: Error {
    case bluetoothNotAvailable(CBMManagerState)
}

extension BluetoothManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bluetoothNotAvailable(let state):
            switch state {
            case .poweredOff:
                return LocalizedString("Bluetooth is powered off", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.poweredOff)")
            case .resetting:
                return LocalizedString("Bluetooth is resetting", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.resetting)")
            case .unauthorized:
                return LocalizedString("Bluetooth use is unauthorized", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unauthorized)")
            case .unsupported:
                return LocalizedString("Bluetooth use unsupported on this device", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unsupported)")
            case .unknown:
                return LocalizedString("Bluetooth is unavailable for an unknown reason.", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unknown)")
            default:
                return String(format: LocalizedString("Bluetooth is unavailable: %1$@", comment: "The format string for BluetoothManagerError.bluetoothNotAvailable for unknown state (1: the unknown state)"), String(describing: state))
            }
        }
    }
        
    public var recoverySuggestion: String? {
        switch self {
        case .bluetoothNotAvailable(let state):
            switch state {
            case .poweredOff:
                return LocalizedString("Turn bluetooth on", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.poweredOff)")
            case .resetting:
                return LocalizedString("Try again", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.resetting)")
            case .unauthorized:
                return LocalizedString("Please enable bluetooth permissions for this app in system settings", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.unauthorized)")
            case .unsupported:
                return LocalizedString("Please use a different device with bluetooth capabilities", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.unsupported)")
            default:
                return nil
            }
        }
    }
}

protocol OmniBLEConnectionDelegate: AnyObject {

    /**
     Tells the delegate that a peripheral has been connected to

     - parameter manager: The manager for the peripheral that was connected
     */
    func omnipodPeripheralDidConnect(manager: PeripheralManager)
    
    /**
     Tells the delegate that a connected peripheral has been restored from session restoration

     - parameter manager: The manager for the peripheral that was connected
     */
    func omnipodPeripheralWasRestored(manager: PeripheralManager)


    /**
     Tells the delegate that a peripheral was disconnected

     - parameter peripheral: The peripheral that was disconnected
     */
    func omnipodPeripheralDidDisconnect(peripheral: CBMPeripheral, error: Error?)

    /**
     Tells the delegate that a peripheral failed to connect

     - parameter peripheral: The peripheral that failed to connect
     */
    func omnipodPeripheralDidFailToConnect(peripheral: CBMPeripheral, error: Error?)

}


class BluetoothManager: NSObject {

    weak var connectionDelegate: OmniBLEConnectionDelegate?

    private let log = OSLog(category: "BluetoothManager")

    /// Isolated to `managerQueue`
    private var manager: CBMCentralManager! = nil

    /// Test-only accessor for the underlying CBMCentralManager. Used by
    /// T.1 integration tests to install a queue-bouncing delegate wrapper
    /// that works around CoreBluetoothMock's main-thread delegate delivery
    /// (which trips the dispatchPrecondition checks throughout this class).
    /// NOT for production use.
    internal var centralManagerForTesting: CBMCentralManager! { manager }

    /// Test-only accessor for the private background managerQueue. The
    /// queue-bouncing wrapper needs this to dispatch CBM callbacks back
    /// onto the queue OmniBLE expects. NOT for production use.
    internal var managerQueueForTesting: DispatchQueue { managerQueue }

    /// Isolated to `managerQueue`
    private var devices: [OmniBLE] = []
    
    /// Isolated to `managerQueue`
    private var discoveryModeEnabled: Bool = false

    /// Isolated to `managerQueue`
    private var autoConnectIDs: Set<String> = [] {
        didSet {
            updateConnections()
            // T.1 finding: if a new ID was added, kick off a scan so we can
            // discover the peripheral. Without this, watch-side handoff hangs
            // forever because centralManagerDidUpdateState already fired during
            // init with an empty set (so hasDiscoveredAllAutoConnectDevices was
            // vacuously true and no scan started). Adding an ID later doesn't
            // re-trigger that callback, so we have to nudge the scan ourselves.
            if manager?.state == .poweredOn
                && !hasDiscoveredAllAutoConnectDevices
                && !(manager?.isScanning ?? false) {
                startScanning()
            }
        }
    }
    
    /// Isolated to `managerQueue`
    private var hasDiscoveredAllAutoConnectDevices: Bool {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        return autoConnectIDs.isSubset(of: devices.map { $0.manager.peripheral.identifier.uuidString })
    }

    // MARK: - Synchronization
    private let managerQueue = DispatchQueue(label: "com.OmniBLE.bluetoothManagerQueue", qos: .unspecified)

    override init() {
        super.init()

        managerQueue.sync {
            self.manager = CBMCentralManagerFactory.instance(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.OmniBLE"], forceMock: false)
        }
    }
    
    @discardableResult
    private func addPeripheral(_ peripheral: CBMPeripheral, podAdvertisement: PodAdvertisement?) -> OmniBLE {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        var device: OmniBLE! = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier })

        if let device = device {
            log.default("Matched peripheral %{public}@ to existing device: %{public}@", peripheral.identifier.uuidString, String(describing: device))
            device.manager.peripheral = peripheral
            if let podAdvertisement = podAdvertisement {
                device.advertisement = podAdvertisement
            }
        } else {
            device = OmniBLE(peripheralManager: PeripheralManager(peripheral: peripheral, configuration: .omnipod, centralManager: manager), advertisement: podAdvertisement)
            devices.append(device)
            log.info("Created device")
        }
        return device
    }
    
    // MARK: - Actions
    
    func discoverPods(completion: @escaping (BluetoothManagerError?) -> Void) {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            self.discoverPods(completion)
        }
    }
    
    func endPodDiscovery() {
        managerQueue.sync {
            self.discoveryModeEnabled = false
            self.manager.stopScan()
            
            // Disconnect from all devices not in our connection list
            for device in devices {
                let peripheral = device.manager.peripheral
                if !autoConnectIDs.contains(peripheral.identifier.uuidString) &&
                   (peripheral.state == .connected || peripheral.state == .connecting)
                {
                    log.default("Disconnecting from peripheral: %{public}@", peripheral.identifier.uuidString)
                    manager.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }
    
    func connectToDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.insert(uuidString)
        }
    }
    
    func disconnectFromDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.remove(uuidString)
        }
    }
    
    private func updateConnections() {
        guard manager.state == .poweredOn else {
            log.debug("Skipping updateConnections until state is poweredOn")
            return
        }
        
        for device in devices {
            let peripheral = device.manager.peripheral
            if autoConnectIDs.contains(peripheral.identifier.uuidString) {
                if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                    log.info("updateConnections: Connecting to peripheral: %{public}@", peripheral.identifier.uuidString)
                    manager.connect(peripheral, options: nil)
                }
            } else {
                if peripheral.state == .connected || peripheral.state == .connecting {
                    log.info("updateConnections: Disconnecting from peripheral: %{public}@", peripheral.identifier.uuidString)
                    manager.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }

    private func discoverPods(_ completion: @escaping (BluetoothManagerError?) -> Void) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("discoverPods()")
        

        guard manager.state == .poweredOn else {
            completion(.bluetoothNotAvailable(manager.state))
            return
        }

        // We will attempt to connect to all pairable devices when in discovery mode
        discoveryModeEnabled = true
        for device in devices {
            let peripheral = device.manager.peripheral
            if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                log.info("discoverPods: Connecting to peripheral: %{public}@", peripheral.identifier.uuidString)
                manager.connect(peripheral, options: nil)
            }
        }
        startScanning()

        completion(nil)
    }
    
    private func startScanning() {
        log.default("Start scanning")
        manager.scanForPeripherals(withServices: [OmnipodServiceUUID.advertisement.cbUUID], options: nil)
    }

    private func stopScanning() {
        log.default("Stop scanning")
        manager.stopScan()
    }

    // MARK: - Accessors
    
    public func getConnectedDevices() -> [OmniBLE] {
        var connected: [OmniBLE] = []
        managerQueue.sync {
            connected = self.devices.filter { $0.manager.peripheral.state == .connected }
        }
        return connected
    }

    override var debugDescription: String {
        
        var report = [
            "## BluetoothManager",
            "central: \(manager!)"
        ]

        for device in devices {
            report.append(String(reflecting: device))
            report.append("")
        }

        return report.joined(separator: "\n\n")
    }
}


extension BluetoothManager: CBMCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBMCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("%{public}@: %{public}@", #function, String(describing: central.state.rawValue))

        if case .poweredOn = central.state {
            // bluetooth may have reset; update peripheral references
            for device in devices {
                if let newPeripheral = central.retrievePeripherals(withIdentifiers: [device.manager.peripheral.identifier]).first {
                    log.debug("Re-connecting to known peripheral %{public}@", newPeripheral.identifier.uuidString)
                    device.manager.peripheral = newPeripheral
                    central.connect(newPeripheral)
                }
            }

            updateConnections()
            
            if (discoveryModeEnabled || !hasDiscoveredAllAutoConnectDevices) && !manager.isScanning {
                startScanning()
            } else if !discoveryModeEnabled && manager.isScanning {
                stopScanning()
            }
        }

        for device in devices {
            device.manager.assertConfiguration()
        }
    }

    func centralManager(_ central: CBMCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.info("OmniBLE %{public}@: %{public}@", #function, dict)

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBMPeripheral] {
            for peripheral in peripherals {
                let device = addPeripheral(peripheral, podAdvertisement: nil)
                
                if autoConnectIDs.contains(peripheral.identifier.uuidString) {
                    if peripheral.state == .connected {
                        connectionDelegate?.omnipodPeripheralWasRestored(manager: device.manager)
                    }
                } else if peripheral.state == .connected || peripheral.state == .connecting {
                    // For some reason iOS is maintaining a connection to a device that isn't in our list.
                    manager.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }

    func centralManager(_ central: CBMCentralManager, didDiscover peripheral: CBMPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.debug("%{public}@: %{public}@, %{public}@", #function, peripheral.identifier.uuidString, advertisementData)
        
        if let podAdvertisement = PodAdvertisement(advertisementData) {
            addPeripheral(peripheral, podAdvertisement: podAdvertisement)
            
            if discoveryModeEnabled && peripheral.state == .disconnected && podAdvertisement.pairable {
                // Connect to any pairable device, during discovery
                log.default("Connecting to pairable device %{public}@ in discovery mode", peripheral.identifier.uuidString)
                manager.connect(peripheral, options: nil)
            } else if autoConnectIDs.contains(peripheral.identifier.uuidString) && peripheral.state == .disconnected {
                log.debug("Reonnecting to autoconnect device")
                manager.connect(peripheral, options: nil)
            } else {
                log.info("Ignoring paired or unconnectable peripheral: %{public}@", peripheral.identifier.uuidString)
            }
        } else {
            log.info("Ignoring peripheral with unexpected advertisement data: %{public}@", advertisementData)
        }
        
        if !discoveryModeEnabled && central.isScanning && hasDiscoveredAllAutoConnectDevices {
            log.debug("All peripherals discovered")
            stopScanning()
        }
    }

    func centralManager(_ central: CBMCentralManager, didConnect peripheral: CBMPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.debug("%{public}@: %{public}@", #function, peripheral.identifier.uuidString)
        
        // Proxy connection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didConnect: peripheral)
            connectionDelegate?.omnipodPeripheralDidConnect(manager: device.manager)

            // Get an RSSI reading for logging
            peripheral.readRSSI()
        }
    }

    func centralManager(_ central: CBMCentralManager, didDisconnectPeripheral peripheral: CBMPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.debug("%{public}@: error=%{public}@ %{public}@", #function, error?.localizedDescription ?? "None", peripheral.identifier.uuidString)

        // Proxy disconnection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didDisconnect: peripheral, error: error)
        }

        connectionDelegate?.omnipodPeripheralDidDisconnect(peripheral: peripheral, error: error)

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            log.debug("Reconnecting disconnected autoconnect peripheral")
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBMCentralManager, didFailToConnect peripheral: CBMPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.error("%{public}@: %{public}@", #function, String(describing: error))

        connectionDelegate?.omnipodPeripheralDidFailToConnect(peripheral: peripheral, error: error)

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            central.connect(peripheral, options: nil)
        }
    }
}
