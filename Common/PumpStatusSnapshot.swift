//
//  PumpStatusSnapshot.swift
//  OmniBLE
//
//  Flat snapshot of pump state included in `AlgorithmStateSnapshot`. The
//  watch uses this as a hint at takeover; the live pod is authoritative
//  once bonded.
//

import Foundation

public struct PumpStatusSnapshot: Codable, Equatable, Sendable {
    public let reservoirUnitsRemaining: Double
    public let lastBasalRateUnitsPerHour: Double?
    public let isSuspended: Bool
    public let lastReadingDate: Date

    public init(reservoirUnitsRemaining: Double,
                lastBasalRateUnitsPerHour: Double?,
                isSuspended: Bool,
                lastReadingDate: Date) {
        self.reservoirUnitsRemaining = reservoirUnitsRemaining
        self.lastBasalRateUnitsPerHour = lastBasalRateUnitsPerHour
        self.isSuspended = isSuspended
        self.lastReadingDate = lastReadingDate
    }
}
