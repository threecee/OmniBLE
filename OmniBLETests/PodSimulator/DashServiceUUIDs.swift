//
//  DashServiceUUIDs.swift
//  OmniBLETests
//
//  Mirror of the BLE service/characteristic UUIDs used by real Omnipod DASH
//  pods, for use by MockOmnipodPeripheral. MUST match OmniBLE production
//  constants (OmnipodServiceUUID / OmnipodCharacteristicUUID in
//  OmniBLE/Bluetooth/BluetoothServices.swift) and the Go bridge's CmdCharUUID/
//  DataCharUUID byte arrays exactly. Out-of-sync UUIDs cause silent
//  connection failure.
//

import CoreBluetooth
import CoreBluetoothMock

enum DashServiceUUIDs {
    /// Primary DASH service UUID.
    /// Matches OmnipodServiceUUID.service = "1A7E4024-E3ED-4464-8B7E-751E03D0DC5F"
    static let service = CBUUID(string: "1A7E4024-E3ED-4464-8B7E-751E03D0DC5F")

    /// Command characteristic (central writes commands here).
    /// Matches OmnipodCharacteristicUUID.command = "1A7E2441-E3ED-4464-8B7E-751E03D0DC5F"
    /// Matches Go bridge CmdCharUUID = {0x1a,0x7e,0x24,0x41,...}
    static let cmdCharacteristic = CBUUID(string: "1A7E2441-E3ED-4464-8B7E-751E03D0DC5F")

    /// Data characteristic (central subscribes for notifications).
    /// Matches OmnipodCharacteristicUUID.data = "1A7E2442-E3ED-4464-8B7E-751E03D0DC5F"
    /// Matches Go bridge DataCharUUID = {0x1a,0x7e,0x24,0x42,...}
    static let dataCharacteristic = CBUUID(string: "1A7E2442-E3ED-4464-8B7E-751E03D0DC5F")
}
