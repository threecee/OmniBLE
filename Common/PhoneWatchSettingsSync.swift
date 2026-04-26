//
//  PhoneWatchSettingsSync.swift
//  OmniBLE
//
//  Phone -> Watch settings synchronization message. Sent on WCSession connect,
//  on settings change while watch is driver, and at handoff. Watch caches
//  locally; LoopDataManager reads from the cache.
//
//  Part of B.3.a (watch self-driving). Extends the B.2.c WCSession protocol.
//

import Foundation
import LoopKit

public struct PhoneWatchSettingsSync: Codable, Equatable {
    public let protocolVersion: Int
    public let sentAt: Date

    /// Basal rate schedule items (second offsets + units/hour).
    public let basalScheduleItems: [RepeatingScheduleValue<Double>]

    /// Insulin sensitivity schedule items (second offsets + mg/dL per unit).
    public let insulinSensitivityScheduleItems: [RepeatingScheduleValue<Double>]

    /// Carb ratio schedule items (second offsets + grams per unit).
    public let carbRatioScheduleItems: [RepeatingScheduleValue<Double>]

    /// Glucose target range schedule items (second offsets + mg/dL min-max).
    public let glucoseTargetRangeScheduleItems: [RepeatingScheduleValue<DoubleRange>]

    public let maximumBolusUnits: Double
    public let maximumBasalRatePerHourUnits: Double

    /// Suspend threshold in mg/dL. Nil means no suspend threshold configured.
    public let suspendThresholdMgdL: Double?

    /// Nightscout integration config. Nil means Nightscout not configured —
    /// receiving side MUST NOT start Nightscout polling when nil.
    public let nightscoutConfig: NightscoutConfig?

    public init(
        protocolVersion: Int,
        sentAt: Date,
        basalScheduleItems: [RepeatingScheduleValue<Double>],
        insulinSensitivityScheduleItems: [RepeatingScheduleValue<Double>],
        carbRatioScheduleItems: [RepeatingScheduleValue<Double>],
        glucoseTargetRangeScheduleItems: [RepeatingScheduleValue<DoubleRange>],
        maximumBolusUnits: Double,
        maximumBasalRatePerHourUnits: Double,
        suspendThresholdMgdL: Double?,
        nightscoutConfig: NightscoutConfig?
    ) {
        self.protocolVersion = protocolVersion
        self.sentAt = sentAt
        self.basalScheduleItems = basalScheduleItems
        self.insulinSensitivityScheduleItems = insulinSensitivityScheduleItems
        self.carbRatioScheduleItems = carbRatioScheduleItems
        self.glucoseTargetRangeScheduleItems = glucoseTargetRangeScheduleItems
        self.maximumBolusUnits = maximumBolusUnits
        self.maximumBasalRatePerHourUnits = maximumBasalRatePerHourUnits
        self.suspendThresholdMgdL = suspendThresholdMgdL
        self.nightscoutConfig = nightscoutConfig
    }

    public struct NightscoutConfig: Codable, Equatable {
        public let url: URL
        public let apiSecret: String

        public init(url: URL, apiSecret: String) {
            self.url = url
            self.apiSecret = apiSecret
        }
    }
}
