//
//  PhoneWatchPairingHandoff.swift
//  OmniBLE
//
//  Conveys pod pairing credentials from phone to watch (when watch is taking
//  over as driver) or back to phone (on handoff reversal). The pairingPayload
//  is OPAQUE at the protocol layer — its internal structure is pod-specific and
//  can evolve inside OmniBLE without re-versioning PhoneWatchProtocol.
//

import Foundation

public struct PhoneWatchPairingHandoff: Codable, Equatable {
    public let protocolVersion: Int
    public let sentAt: Date
    public let podId: String
    public let pairingPayload: Data
    public let validUntil: Date
    public let transitionId: UUID

    public init(protocolVersion: Int, sentAt: Date, podId: String,
                pairingPayload: Data, validUntil: Date, transitionId: UUID) {
        self.protocolVersion = protocolVersion
        self.sentAt = sentAt
        self.podId = podId
        self.pairingPayload = pairingPayload
        self.validUntil = validUntil
        self.transitionId = transitionId
    }
}
