//
//  MockOmnipodPeripheral.swift
//  OmniBLETests
//
//  CBMPeripheralSpec that advertises real DASH service/characteristic UUIDs
//  and bridges all GATT events to a PodSimulatorBridge subprocess.
//
//  Each test method gets its own MockOmnipodPeripheral, paired with its own
//  PodSimulatorBridge — see PodSimulatorTestCase.
//

import Foundation
import CoreBluetooth
import CoreBluetoothMock

final class MockOmnipodPeripheral {

    let bridge: PodSimulatorBridge
    let identifier: UUID

    init(bridge: PodSimulatorBridge, identifier: UUID = UUID()) {
        self.bridge = bridge
        self.identifier = identifier
    }

    /// Build the CBMPeripheralSpec that simulates the pod for one test.
    /// Caller is responsible for registering with CBMCentralManagerMock.simulatePeripherals.
    func makeSpec() -> CBMPeripheralSpec {
        let cmdChar = CBMCharacteristicMock(
            type: DashServiceUUIDs.cmdCharacteristic,
            properties: [.write, .writeWithoutResponse]
        )
        let dataChar = CBMCharacteristicMock(
            type: DashServiceUUIDs.dataCharacteristic,
            properties: [.notify, .read],
            descriptors: CBMClientCharacteristicConfigurationDescriptorMock()
        )
        let service = CBMServiceMock(
            type: DashServiceUUIDs.service,
            primary: true,
            characteristics: cmdChar, dataChar
        )

        return CBMPeripheralSpec
            .simulatePeripheral(identifier: identifier, proximity: .immediate)
            .advertising(
                advertisementData: [
                    CBMAdvertisementDataLocalNameKey: "Pod-mock",
                    // Advertise BOTH the advertisement UUID (what OmniBLE's
                    // BluetoothManager scans for) and the full service UUID
                    // (so direct CBM-level scans in PodConnectionTests still
                    // discover us).
                    CBMAdvertisementDataServiceUUIDsKey: [
                        DashServiceUUIDs.advertisement,
                        DashServiceUUIDs.service,
                    ],
                    CBMAdvertisementDataIsConnectable: true
                ],
                withInterval: 0.250,
                alsoWhenConnected: false
            )
            .connectable(
                name: "Pod-mock",
                services: [service],
                delegate: PodMockDelegate(bridge: bridge),
                connectionInterval: 0.150,
                mtu: 23
            )
            .build()
    }
}

/// CBMPeripheralSpecDelegate that translates CBM events into bridge frames.
private final class PodMockDelegate: CBMPeripheralSpecDelegate {

    let bridge: PodSimulatorBridge
    private var connected = false

    init(bridge: PodSimulatorBridge) {
        self.bridge = bridge
    }

    func peripheralDidReceiveConnectionRequest(_ peripheral: CBMPeripheralSpec) -> Result<Void, Error> {
        do {
            try bridge.send(type: .connect, payload: Data())
            // Block briefly waiting for CONNECT_ACK so the test sees a clean connect timeline
            let resp = try bridge.receive(timeout: 2.0)
            guard resp.type == .connectAck else {
                return .failure(MockOmnipodError.unexpectedResponse(resp.type))
            }
            connected = true
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func peripheral(_ peripheral: CBMPeripheralSpec, didDisconnect error: Error?) {
        connected = false
        try? bridge.send(type: .disconnect, payload: Data())
        // Drain DISCONNECT_ACK so it isn't sitting in the buffer when the next
        // CONNECT cycle starts (otherwise the next peripheralDidReceiveConnectionRequest
        // reads DISCONNECT_ACK instead of CONNECT_ACK and the connect appears to fail).
        // Best-effort; if the bridge is dead this just times out cleanly.
        _ = try? bridge.receive(timeout: 0.5)
    }

    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveWriteRequestFor characteristic: CBMCharacteristicMock,
                    data: Data) -> Result<Void, Error> {
        guard connected else { return .failure(MockOmnipodError.notConnected) }
        // Build WRITE payload: UUID bytes + data
        var payload = Data(capacity: characteristic.uuid.data.count + data.count)
        payload.append(characteristic.uuid.data)
        payload.append(data)

        do {
            try bridge.send(type: .write, payload: payload)
            // Drain notifications asynchronously so we don't block the GATT delegate
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.drainNotifications(toCharacteristic: characteristic, on: peripheral)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveWriteCommandFor characteristic: CBMCharacteristicMock,
                    data: Data) {
        guard connected else { return }
        // Build WRITE payload: UUID bytes + data
        var payload = Data(capacity: characteristic.uuid.data.count + data.count)
        payload.append(characteristic.uuid.data)
        payload.append(data)

        try? bridge.send(type: .write, payload: payload)
        // Drain notifications asynchronously
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.drainNotifications(toCharacteristic: characteristic, on: peripheral)
        }
    }

    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveSetNotifyRequest enabled: Bool,
                    for characteristic: CBMCharacteristicMock) -> Result<Void, Error> {
        let msgType: BridgeMessageType = enabled ? .subscribe : .unsubscribe
        do {
            try bridge.send(type: msgType, payload: characteristic.uuid.data)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func drainNotifications(toCharacteristic char: CBMCharacteristicMock, on peripheral: CBMPeripheralSpec) {
        // Read up to a few NOTIFYs that the pod may have queued in response to the WRITE.
        // Stop on timeout (no more notifications coming for now).
        for _ in 0..<8 {
            do {
                let frame = try bridge.receive(timeout: 0.2)
                if frame.type == .notify {
                    // Payload: UUID bytes + notification data; skip UUID prefix
                    let uuidLen = char.uuid.data.count
                    guard frame.payload.count >= uuidLen else { continue }
                    let data = frame.payload.subdata(in: uuidLen..<frame.payload.count)
                    DispatchQueue.main.async {
                        peripheral.simulateValueUpdate(data, for: char)
                    }
                }
            } catch PodSimulatorBridgeError.timeout {
                return
            } catch {
                return
            }
        }
    }
}

enum MockOmnipodError: Error {
    case unexpectedResponse(BridgeMessageType)
    case notConnected
}
