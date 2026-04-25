//
//  PodConnectionTests.swift
//  OmniBLETests
//
//  Integration tests for raw BLE connect/disconnect/reconnect lifecycle through
//  OmniBLE's BluetoothManager. Full set lands in Phase 5; this Phase 4 file
//  has just the smoke test.
//

import XCTest
import CoreBluetooth
import CoreBluetoothMock
@testable import OmniBLE

final class PodConnectionTests: PodSimulatorTestCase {

    /// Phase 4 smoke test: scan finds the mock peripheral and the bridge
    /// receives a CONNECT message (proven by the connection succeeding —
    /// MockOmnipodPeripheral's peripheralDidReceiveConnectionRequest only
    /// returns .success after CONNECT_ACK round-trips).
    func testConnectToAdvertisingPod() throws {
        let cd = ConnectExpectationDelegate()
        let manager = CBMCentralManagerFactory.instance(delegate: cd, queue: nil, forceMock: true)

        // Wait for poweredOn
        let powerExp = expectation(description: "poweredOn")
        cd.onStateChange = { state in
            if state == .poweredOn { powerExp.fulfill() }
        }
        wait(for: [powerExp], timeout: 2.0)

        // Scan + connect
        let connExp = expectation(description: "connected")
        cd.onConnect = { _ in connExp.fulfill() }
        manager.scanForPeripherals(withServices: [DashServiceUUIDs.service])
        wait(for: [connExp], timeout: 5.0)

        XCTAssertNotNil(cd.connectedPeripheral)
    }
}

private final class ConnectExpectationDelegate: NSObject, CBMCentralManagerDelegate {
    var onStateChange: ((CBMManagerState) -> Void)?
    var onConnect: ((CBMPeripheral) -> Void)?
    var connectedPeripheral: CBMPeripheral?

    func centralManagerDidUpdateState(_ central: CBMCentralManager) {
        onStateChange?(central.state)
    }
    func centralManager(_ central: CBMCentralManager, didDiscover peripheral: CBMPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        connectedPeripheral = peripheral
        central.connect(peripheral)
    }
    func centralManager(_ central: CBMCentralManager, didConnect peripheral: CBMPeripheral) {
        onConnect?(peripheral)
    }
}
