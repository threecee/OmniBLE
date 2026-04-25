//
//  CBMSpikeTests.swift
//  OmniBLETests
//
//  Validates Nordic CoreBluetoothMock behaviors that T.1's design depends on.
//  Started as a Phase 4 spike (per spec Q4.2); kept as ongoing regression
//  coverage of the assumptions baked into MockOmnipodPeripheral and Phase 8.
//

import XCTest
import CoreBluetooth
import CoreBluetoothMock
@testable import OmniBLE

final class CBMSpikeTests: XCTestCase {

    /// The DASH pod service UUID — MIRROR OF the production constant.
    /// Update both if either changes.
    private let serviceUUID = CBUUID(string: "1A7E4024-E3ED-4464-8B7E-751E03D0DC5F")

    override func setUp() {
        super.setUp()
        CBMCentralManagerMock.simulateInitialState(.poweredOn)
    }

    override func tearDown() {
        CBMCentralManagerMock.tearDownSimulation()
        super.tearDown()
    }

    /// Spike A: a single central can scan, find a mocked peripheral, and connect.
    func testSpike_singleCentralFindsMockPeripheral() throws {
        let mockPeripheral = makeMinimalMockPeripheral()
        CBMCentralManagerMock.simulatePeripherals([mockPeripheral])

        let scanProxy = ScanDelegate(serviceUUID: serviceUUID)
        let manager = CBMCentralManagerFactory.instance(delegate: scanProxy, queue: nil, forceMock: true)

        let scanExpectation = XCTestExpectation(description: "scan finds peripheral")
        scanProxy.onDiscover = { _ in scanExpectation.fulfill() }

        wait(forCondition: { manager.state == .poweredOn }, timeout: 2.0)
        manager.scanForPeripherals(withServices: [serviceUUID])
        wait(for: [scanExpectation], timeout: 3.0)
    }

    /// Spike B (Q4.2): two CBMCentralManager instances simultaneously.
    /// If this passes, Phase 8 has flexibility in handoff design.
    /// If only Spike C passes (B fails), Phase 8 uses sequential pattern.
    func testSpike_twoCentralsCanCoexist() throws {
        let mockPeripheral = makeMinimalMockPeripheral()
        CBMCentralManagerMock.simulatePeripherals([mockPeripheral])

        let proxy1 = ScanDelegate(serviceUUID: serviceUUID)
        let proxy2 = ScanDelegate(serviceUUID: serviceUUID)
        let manager1 = CBMCentralManagerFactory.instance(delegate: proxy1, queue: nil, forceMock: true)
        let manager2 = CBMCentralManagerFactory.instance(delegate: proxy2, queue: nil, forceMock: true)

        wait(forCondition: { manager1.state == .poweredOn && manager2.state == .poweredOn }, timeout: 2.0)

        let exp1 = XCTestExpectation(description: "manager1 scan finds peripheral")
        let exp2 = XCTestExpectation(description: "manager2 scan finds peripheral")
        proxy1.onDiscover = { _ in exp1.fulfill() }
        proxy2.onDiscover = { _ in exp2.fulfill() }

        manager1.scanForPeripherals(withServices: [serviceUUID])
        manager2.scanForPeripherals(withServices: [serviceUUID])

        wait(for: [exp1, exp2], timeout: 3.0)
    }

    /// Spike C (Q4.2): only one central can hold a connection at a time.
    /// If this passes (and Spike B passes too), Phase 8 can use sequential
    /// "phone-then-watch" pattern: phone disconnects, watch connects.
    func testSpike_secondCentralCanConnectAfterFirstDisconnects() throws {
        let mockPeripheral = makeMinimalMockPeripheral()
        CBMCentralManagerMock.simulatePeripherals([mockPeripheral])

        let cd1 = ConnectDelegate(serviceUUID: serviceUUID)
        let cd2 = ConnectDelegate(serviceUUID: serviceUUID)
        let manager1 = CBMCentralManagerFactory.instance(delegate: cd1, queue: nil, forceMock: true)
        let manager2 = CBMCentralManagerFactory.instance(delegate: cd2, queue: nil, forceMock: true)
        wait(forCondition: { manager1.state == .poweredOn && manager2.state == .poweredOn }, timeout: 2.0)

        // Manager1: scan → connect
        let connectExp1 = XCTestExpectation(description: "manager1 connects")
        cd1.onConnect = { _ in connectExp1.fulfill() }
        manager1.scanForPeripherals(withServices: [serviceUUID])
        wait(for: [connectExp1], timeout: 5.0)

        // Manager1: disconnect
        let disconnectExp = XCTestExpectation(description: "manager1 disconnects")
        cd1.onDisconnect = { _ in disconnectExp.fulfill() }
        if let p = cd1.connectedPeripheral { manager1.cancelPeripheralConnection(p) }
        wait(for: [disconnectExp], timeout: 3.0)

        // Manager2: now scan and connect
        let connectExp2 = XCTestExpectation(description: "manager2 connects after manager1 released")
        cd2.onConnect = { _ in connectExp2.fulfill() }
        manager2.scanForPeripherals(withServices: [serviceUUID])
        wait(for: [connectExp2], timeout: 5.0)
    }

    // MARK: - Helpers

    private func makeMinimalMockPeripheral() -> CBMPeripheralSpec {
        return CBMPeripheralSpec
            .simulatePeripheral(identifier: UUID(), proximity: .immediate)
            .advertising(
                advertisementData: [CBMAdvertisementDataServiceUUIDsKey: [serviceUUID]],
                withInterval: 0.250,
                alsoWhenConnected: false
            )
            .connectable(
                name: "MockPod",
                services: [],
                delegate: NoopMockDelegate(),
                connectionInterval: 0.150,
                mtu: 23
            )
            .build()
    }

    private func wait(forCondition condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

// MARK: - Throwaway delegates for the spike

private final class ScanDelegate: NSObject, CBMCentralManagerDelegate {
    let serviceUUID: CBUUID
    var onDiscover: ((CBMPeripheral) -> Void)?
    init(serviceUUID: CBUUID) { self.serviceUUID = serviceUUID }
    func centralManagerDidUpdateState(_ central: CBMCentralManager) {}
    func centralManager(_ central: CBMCentralManager, didDiscover peripheral: CBMPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        onDiscover?(peripheral)
    }
}

private final class ConnectDelegate: NSObject, CBMCentralManagerDelegate {
    let serviceUUID: CBUUID
    var onConnect: ((CBMPeripheral) -> Void)?
    var onDisconnect: ((CBMPeripheral) -> Void)?
    var connectedPeripheral: CBMPeripheral?
    init(serviceUUID: CBUUID) { self.serviceUUID = serviceUUID }
    func centralManagerDidUpdateState(_ central: CBMCentralManager) {}
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
}

private final class NoopMockDelegate: CBMPeripheralSpecDelegate {}
