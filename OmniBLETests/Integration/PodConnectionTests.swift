//
//  PodConnectionTests.swift
//  OmniBLETests
//
//  Integration tests for raw BLE connect/disconnect/reconnect lifecycle through
//  CoreBluetoothMock + MockOmnipodPeripheral + PodSimulatorBridge. These tests
//  exercise the wire-protocol round-trip ONLY (connect → CONNECT/CONNECT_ACK,
//  disconnect → DISCONNECT). They do NOT touch encrypted pairing — that lives
//  in PodActivationTests.
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

        // Wait for poweredOn — CBM may fire state-change multiple times on
        // slow CI; we only care about the first poweredOn.
        let powerExp = expectation(description: "poweredOn")
        powerExp.assertForOverFulfill = false
        cd.onStateChange = { state in
            if state == .poweredOn { powerExp.fulfill() }
        }
        wait(for: [powerExp], timeout: 2.0)

        // Scan + connect — didConnect can fire more than once on slow runners
        // (rediscovery + reconnect race). Only the first fulfill matters.
        let connExp = expectation(description: "connected")
        connExp.assertForOverFulfill = false
        cd.onConnect = { _ in connExp.fulfill() }
        manager.scanForPeripherals(withServices: [DashServiceUUIDs.advertisement])
        wait(for: [connExp], timeout: 5.0)

        XCTAssertNotNil(cd.connectedPeripheral)
    }

    /// Phase 5: clean disconnect. Connect first, then cancel the connection
    /// and verify the disconnect callback fires. The MockOmnipodPeripheral
    /// delegate forwards a DISCONNECT frame to the bridge in response.
    func testDisconnectGracefully() throws {
        let cd = ConnectExpectationDelegate()
        let manager = CBMCentralManagerFactory.instance(delegate: cd, queue: nil, forceMock: true)

        // Power on
        let powerExp = expectation(description: "poweredOn")
        powerExp.assertForOverFulfill = false
        cd.onStateChange = { state in if state == .poweredOn { powerExp.fulfill() } }
        wait(for: [powerExp], timeout: 2.0)

        // Connect
        let connExp = expectation(description: "connected")
        connExp.assertForOverFulfill = false
        cd.onConnect = { _ in connExp.fulfill() }
        manager.scanForPeripherals(withServices: [DashServiceUUIDs.advertisement])
        wait(for: [connExp], timeout: 5.0)
        guard let peripheral = cd.connectedPeripheral else {
            XCTFail("no peripheral after connect; stderr: \(self.bridge.stderrTail())")
            return
        }
        XCTAssertEqual(peripheral.state, .connected)

        // Disconnect — didDisconnect can fire repeatedly on retries.
        let disconnectExp = expectation(description: "disconnected")
        disconnectExp.assertForOverFulfill = false
        cd.onDisconnect = { _ in disconnectExp.fulfill() }
        manager.cancelPeripheralConnection(peripheral)
        wait(for: [disconnectExp], timeout: 3.0)

        XCTAssertEqual(peripheral.state, .disconnected)
    }

    /// Phase 5: reconnect after disconnect. Same central, same peripheral —
    /// connect, disconnect, then connect again. Mirrors CBMSpikeTests' Spike C
    /// pattern but exercises MockOmnipodPeripheral (which round-trips through
    /// the bridge subprocess) rather than a bare CBMPeripheralSpec.
    ///
    /// Note: a single bridge subprocess can only handle ONE pairing/connection
    /// session in its current implementation — after CONNECT the pod sim begins
    /// the activation handshake on its first message. For this test we only
    /// exercise BLE connect/disconnect (no encrypted handshake), so reconnecting
    /// to the same bridge works because the pod sim is still parked waiting for
    /// the activation handshake to start.
    func testReconnectAfterDisconnect() throws {
        let cd = ConnectExpectationDelegate()
        let manager = CBMCentralManagerFactory.instance(delegate: cd, queue: nil, forceMock: true)

        let powerExp = expectation(description: "poweredOn")
        powerExp.assertForOverFulfill = false
        cd.onStateChange = { state in if state == .poweredOn { powerExp.fulfill() } }
        wait(for: [powerExp], timeout: 2.0)

        // 1st connect
        let conn1Exp = expectation(description: "first connected")
        conn1Exp.assertForOverFulfill = false
        cd.onConnect = { _ in conn1Exp.fulfill() }
        manager.scanForPeripherals(withServices: [DashServiceUUIDs.advertisement])
        wait(for: [conn1Exp], timeout: 5.0)
        guard let peripheral = cd.connectedPeripheral else {
            XCTFail("no peripheral after first connect; stderr: \(self.bridge.stderrTail())")
            return
        }

        // Disconnect
        let disconnectExp = expectation(description: "disconnected")
        disconnectExp.assertForOverFulfill = false
        cd.onDisconnect = { _ in disconnectExp.fulfill() }
        manager.cancelPeripheralConnection(peripheral)
        wait(for: [disconnectExp], timeout: 3.0)
        XCTAssertEqual(peripheral.state, .disconnected)

        // 2nd connect — directly call connect on the same peripheral handle
        let conn2Exp = expectation(description: "second connected")
        conn2Exp.assertForOverFulfill = false
        cd.onConnect = { _ in conn2Exp.fulfill() }
        manager.connect(peripheral)
        wait(for: [conn2Exp], timeout: 5.0)
        XCTAssertEqual(peripheral.state, .connected)
    }

    /// Phase 5: connection timeout when the bridge is unresponsive.
    /// We tear down the bridge subprocess BEFORE attempting connect, then
    /// register a peripheral whose CONNECT will hang because the bridge can't
    /// respond. Assert that the connection callback never fires within the
    /// short window.
    ///
    /// Note: CBMCentralManagerMock + CBMPeripheralSpec doesn't natively
    /// support a "connection timeout" CB event the way real BLE does. Instead,
    /// MockOmnipodPeripheral.peripheralDidReceiveConnectionRequest will return
    /// .failure when the bridge is dead (subprocess EOF on receive), which
    /// CBM surfaces as didFailToConnect.
    func testConnectionTimeout() throws {
        // Kill the bridge before attempting to connect
        bridge.terminate()

        let cd = ConnectExpectationDelegate()
        let manager = CBMCentralManagerFactory.instance(delegate: cd, queue: nil, forceMock: true)

        let powerExp = expectation(description: "poweredOn")
        powerExp.assertForOverFulfill = false
        cd.onStateChange = { state in if state == .poweredOn { powerExp.fulfill() } }
        wait(for: [powerExp], timeout: 2.0)

        // Try to connect — expect failure rather than success
        let failExp = expectation(description: "didFailToConnect or stays disconnected")
        failExp.assertForOverFulfill = false  // CBM may retry/fire multiple times
        cd.onConnect = { _ in
            XCTFail("connection unexpectedly succeeded with dead bridge")
        }
        cd.onFailToConnect = { _, _ in failExp.fulfill() }
        manager.scanForPeripherals(withServices: [DashServiceUUIDs.advertisement])

        // Wait up to 3 seconds for failure callback. If neither succeed nor
        // fail-to-connect fires, the test will still pass via timeout — but
        // we want to specifically catch the failure path, so use a short wait.
        wait(for: [failExp], timeout: 3.0)
    }
}

private final class ConnectExpectationDelegate: NSObject, CBMCentralManagerDelegate {
    var onStateChange: ((CBMManagerState) -> Void)?
    var onConnect: ((CBMPeripheral) -> Void)?
    var onDisconnect: ((CBMPeripheral) -> Void)?
    var onFailToConnect: ((CBMPeripheral, Error?) -> Void)?
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
    func centralManager(_ central: CBMCentralManager, didDisconnectPeripheral peripheral: CBMPeripheral, error: Error?) {
        onDisconnect?(peripheral)
    }
    func centralManager(_ central: CBMCentralManager, didFailToConnect peripheral: CBMPeripheral, error: Error?) {
        onFailToConnect?(peripheral, error)
    }
}
