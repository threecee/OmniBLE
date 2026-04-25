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
    public let validUntil: Date           // B.2.e: payload expiration
    public let podSerial: String
    public let serializedPodState: Data
    public let lastBolusSequence: UInt32?
    public let lastBasalScheduleId: UUID?

    public static let currentFormatVersion: Int = 2  // bumped from 1; v1 has no validUntil

    public init(podSerial: String,
                serializedPodState: Data,
                lastBolusSequence: UInt32?,
                lastBasalScheduleId: UUID?,
                validUntil: Date,
                createdAt: Date = Date(),
                formatVersion: Int = OmniBLEHandoffPayload.currentFormatVersion) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.validUntil = validUntil
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

    // MARK: - B.2.e additions

    /// True if `now` is before `validUntil`. Used by OmniBLEOwnership to
    /// avoid restoring stale PodState from an expired payload.
    public func isValid(now: Date) -> Bool {
        return now < validUntil
    }

    /// JSON-encodes the entire payload. Used for App Group persistence.
    public func encoded() throws -> Data {
        return try JSONEncoder().encode(self)
    }

    /// Convenience wrapper that calls decodePodStateRawValue() and constructs
    /// a real PodState from the dictionary. Throws if either step fails.
    public func decodedPodState() throws -> PodState {
        let dict = try decodePodStateRawValue()
        guard let podState = PodState(rawValue: dict) else {
            throw OmniBLEHandoffPayloadError.invalidPodStateFormat
        }
        return podState
    }
}

public enum OmniBLEHandoffPayloadError: Error {
    case invalidPodStateFormat
    case unsupportedFormatVersion(Int)
}

extension OmniBLEHandoffPayload {
    /// B.2.e: Constructs a payload from a current PodState by serializing its
    /// rawValue via PropertyListSerialization. Used by HandoffOrchestrator's
    /// fillPayload helper to populate outgoing pairing-handoff messages.
    public init(podState: PodState,
                lastBolusSequence: UInt32? = nil,
                lastBasalScheduleId: UUID? = nil,
                validUntil: Date = Date(timeIntervalSinceNow: 60)) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: podState.rawValue, format: .binary, options: 0)
        self.init(
            podSerial: podState.bleIdentifier,
            serializedPodState: data,
            lastBolusSequence: lastBolusSequence,
            lastBasalScheduleId: lastBasalScheduleId,
            validUntil: validUntil
        )
    }
}
