//
//  CBMPeripheral.swift
//  xDripG5
//  OmniBLE
//
//  From CGMBLEKit/CGMBLEKit/CBMPeripheral.swift
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import CoreBluetoothMock


// MARK: - Discovery helpers.
extension CBMPeripheral {
    func servicesToDiscover(from serviceUUIDs: [CBUUID]) -> [CBUUID] {
        let knownServiceUUIDs = services?.compactMap({ $0.uuid }) ?? []
        return serviceUUIDs.filter({ !knownServiceUUIDs.contains($0) })
    }

    func characteristicsToDiscover(from characteristicUUIDs: [CBUUID], for service: CBMService) -> [CBUUID] {
        let knownCharacteristicUUIDs = service.characteristics?.compactMap({ $0.uuid }) ?? []
        return characteristicUUIDs.filter({ !knownCharacteristicUUIDs.contains($0) })
    }
}


/// Protocol that captures the `uuid` property shared by CBMService,
/// CBMCharacteristic, and CBMDescriptor. Used in place of `CBAttribute`
/// (which was a CoreBluetooth concrete class; CBMAttribute.uuid is internal).
protocol CBMAttributeProtocol {
    var uuid: CBUUID { get }
}
extension CBMService: CBMAttributeProtocol {}
extension CBMCharacteristic: CBMAttributeProtocol {}
extension CBMDescriptor: CBMAttributeProtocol {}

extension Collection where Element: CBMAttributeProtocol {
    func itemWithUUID(_ uuid: CBUUID) -> Element? {
        for attribute in self {
            if attribute.uuid == uuid {
                return attribute
            }
        }

        return nil
    }
}
