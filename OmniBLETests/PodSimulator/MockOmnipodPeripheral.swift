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
//  Notification routing: a SINGLE persistent drain thread pulls every NOTIFY
//  frame from the bridge stream and dispatches it to the correct
//  characteristic based on the UUID prefix the bridge embeds in each frame.
//  Earlier per-write drain threads dropped notifications and routed them to
//  the wrong characteristic, breaking the multi-step pairing handshake.
//

import Foundation
import CoreBluetooth
import CoreBluetoothMock

final class MockOmnipodPeripheral {

    let bridge: PodSimulatorBridge
    let identifier: UUID

    /// Held strong on the spec so the persistent drain can stop on disconnect.
    private let delegate: PodMockDelegate

    init(bridge: PodSimulatorBridge, identifier: UUID = UUID()) {
        self.bridge = bridge
        self.identifier = identifier
        self.delegate = PodMockDelegate(bridge: bridge)
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

        delegate.cmdCharacteristic = cmdChar
        delegate.dataCharacteristic = dataChar

        return CBMPeripheralSpec
            .simulatePeripheral(identifier: identifier, proximity: .immediate)
            .advertising(
                advertisementData: [
                    CBMAdvertisementDataLocalNameKey: "Pod-mock",
                    CBMAdvertisementDataServiceUUIDsKey: Self.podAdvertisementServiceUUIDs,
                    CBMAdvertisementDataIsConnectable: true
                ],
                withInterval: 0.250,
                alsoWhenConnected: false
            )
            .connectable(
                name: "Pod-mock",
                services: [service],
                delegate: delegate,
                connectionInterval: 0.150,
                mtu: 23
            )
            .build()
    }

    /// 9 short-form service UUIDs in the format OmniBLE's PodAdvertisement
    /// parser expects (see PodAdvertisement.init in OmniBLE/PumpManager/).
    ///
    /// Layout per parser:
    ///   [0] = "4024"     — MAIN_SERVICE_UUID
    ///   [1] = "2470"     — TODO (parser comment: "Alarms?")
    ///   [2] = "000A"     — UNKNOWN_THIRD_SERVICE_UUID
    ///   [3] = "FFFF"     — pairable marker (also high half of podId)
    ///   [4] = "FFFE"     — pairable marker (also low half of podId)
    ///   [5..7] (12 hex chars total, first 10 = lotNo)
    ///                    — lotNo encoded as hex; we use 135601809=0x814A091
    ///                      padded to 10 chars: "000814A091"
    ///                      → [5]="0008", [6]="14A0", [7]="91" + 2 char tail
    ///   [7..8] (8 hex chars; last 6 = sequenceNo after stripping first 2)
    ///                    — sequenceNo=800525=0xC374D padded to 6 chars: "0C374D"
    ///                      → [7] tail = "0C", [8] = "374D"
    ///
    /// The pairable marker matches what real DASH pods broadcast in
    /// unpaired/factory state, which OmniBLE's `discoverPods()` flow targets.
    ///
    /// Short-form CBUUIDs (e.g. `CBUUID(string: "4024")`) expand to the
    /// Bluetooth-base 128-bit form `00004024-0000-1000-8000-00805F9B34FB`,
    /// which is what `OmnipodServiceUUID.advertisement.cbUUID` resolves to,
    /// so OmniBLE's `scanForPeripherals(withServices: [...advertisement])`
    /// matches index [0] of this list.
    static let podAdvertisementServiceUUIDs: [CBUUID] = [
        CBUUID(string: "4024"),
        CBUUID(string: "2470"),
        CBUUID(string: "000A"),
        CBUUID(string: "FFFF"),
        CBUUID(string: "FFFE"),
        CBUUID(string: "0008"),
        CBUUID(string: "14A0"),
        CBUUID(string: "910C"),
        CBUUID(string: "374D"),
    ]
}

/// CBMPeripheralSpecDelegate that translates CBM events into bridge frames.
/// Owns a single persistent drain thread that pulls all NOTIFY frames from
/// the bridge and routes them to the correct CBMCharacteristic based on the
/// UUID prefix in each frame.
private final class PodMockDelegate: CBMPeripheralSpecDelegate {

    let bridge: PodSimulatorBridge

    /// Set by MockOmnipodPeripheral.makeSpec after the characteristics exist.
    /// Held weakly conceptually but as strong references because the spec
    /// itself owns them; cleared on disconnect for hygiene.
    var cmdCharacteristic: CBMCharacteristicMock?
    var dataCharacteristic: CBMCharacteristicMock?

    /// Persistent drain thread. Started on first connect, stopped on disconnect.
    private var drainThread: Thread?
    private let drainShouldStop = NSLock()
    private var _drainShouldStop = false
    private var drainStop: Bool {
        get { drainShouldStop.lock(); defer { drainShouldStop.unlock() }; return _drainShouldStop }
        set { drainShouldStop.lock(); defer { drainShouldStop.unlock() }; _drainShouldStop = newValue }
    }

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
            startDrainThread(peripheral: peripheral)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func peripheral(_ peripheral: CBMPeripheralSpec, didDisconnect error: Error?) {
        connected = false
        stopDrainThread()
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
            // No per-write drain — the persistent drainThread handles all NOTIFYs.
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
        // No per-write drain — the persistent drainThread handles all NOTIFYs.
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

    // MARK: - Persistent NOTIFY drain

    private func startDrainThread(peripheral: CBMPeripheralSpec) {
        guard drainThread == nil else { return }
        drainStop = false

        let thread = Thread { [weak self] in
            self?.drainLoop(peripheral: peripheral)
        }
        thread.name = "MockOmnipodPeripheral.drain"
        thread.start()
        drainThread = thread
    }

    private func stopDrainThread() {
        drainStop = true
        drainThread = nil
    }

    private func drainLoop(peripheral: CBMPeripheralSpec) {
        // Pull NOTIFY frames forever (until disconnect/teardown). For each
        // frame, route to the matching characteristic based on the 16-byte
        // UUID prefix.
        let cmdUUIDBytes = DashServiceUUIDs.cmdCharacteristic.data
        let dataUUIDBytes = DashServiceUUIDs.dataCharacteristic.data

        while !drainStop {
            let frame: (type: BridgeMessageType, payload: Data)
            do {
                // Use a short timeout so we can periodically check drainStop
                // and exit cleanly. The inner loop reschedules continuously.
                frame = try bridge.receive(timeout: 0.1)
            } catch PodSimulatorBridgeError.timeout {
                continue
            } catch {
                return
            }

            guard frame.type == .notify else { continue }
            guard frame.payload.count >= 16 else { continue }
            let uuidPrefix = frame.payload.subdata(in: 0..<16)
            let body = frame.payload.subdata(in: 16..<frame.payload.count)

            let target: CBMCharacteristicMock?
            if uuidPrefix == cmdUUIDBytes {
                target = cmdCharacteristic
            } else if uuidPrefix == dataUUIDBytes {
                target = dataCharacteristic
            } else {
                target = nil
            }

            if let char = target {
                DispatchQueue.main.async {
                    peripheral.simulateValueUpdate(body, for: char)
                }
            }
        }
    }
}

enum MockOmnipodError: Error {
    case unexpectedResponse(BridgeMessageType)
    case notConnected
}
