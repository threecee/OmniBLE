//
//  OmniBLEHandoffPayload.swift
//  OmniBLE
//
//  Defines the interpretation of B.2.c's PhoneWatchPairingHandoff.pairingPayload
//  as an OmniBLE-specific payload: a serialized PodState rawValue dict plus
//  safety re-sync metadata (last bolus sequence, last basal schedule id).
//
//  Note: PodState is RawRepresentable with RawValue == [String: Any], not
//  natively Codable, so we use PropertyListSerialization to round-trip the
//  rawValue dict to/from Data.
//

import Foundation

public struct OmniBLEHandoffPayload: Codable, Equatable {
    public let formatVersion: Int
    public let createdAt: Date
    public let podSerial: String
    public let serializedPodState: Data
    public let lastBolusSequence: UInt32?
    public let lastBasalScheduleId: UUID?

    public static let currentFormatVersion: Int = 1

    public init(podSerial: String,
                serializedPodState: Data,
                lastBolusSequence: UInt32?,
                lastBasalScheduleId: UUID?,
                createdAt: Date = Date(),
                formatVersion: Int = OmniBLEHandoffPayload.currentFormatVersion) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.podSerial = podSerial
        self.serializedPodState = serializedPodState
        self.lastBolusSequence = lastBolusSequence
        self.lastBasalScheduleId = lastBasalScheduleId
    }

    /// Decodes the embedded PodState rawValue dict. Returns the [String: Any]
    /// that PodState's `init(rawValue:)` consumes. Throws if the embedded data
    /// isn't valid property-list-serialized data.
    public func decodePodStateRawValue() throws -> [String: Any] {
        let any = try PropertyListSerialization.propertyList(
            from: serializedPodState, options: [], format: nil)
        guard let dict = any as? [String: Any] else {
            throw OmniBLEHandoffPayloadError.invalidPodStateFormat
        }
        return dict
    }
}

public enum OmniBLEHandoffPayloadError: Error {
    case invalidPodStateFormat
    case unsupportedFormatVersion(Int)
}
