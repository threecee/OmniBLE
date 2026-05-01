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

    /// B.4 Issue #3: Whether the phone has automatic dosing enabled.
    /// Optional + nil-default for backward compatibility with v1 senders;
    /// receivers should treat nil as `false` (fail-closed).
    public let automaticDosingEnabled: Bool?

    /// B.4 Issue #3: Whether automatic dosing is currently allowed
    /// (not blocked by, e.g., a pump comms failure). Optional for
    /// backward compatibility; receivers should treat nil as `false`.
    public let isAutomaticDosingAllowed: Bool?

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
        nightscoutConfig: NightscoutConfig?,
        automaticDosingEnabled: Bool? = nil,
        isAutomaticDosingAllowed: Bool? = nil
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
        self.automaticDosingEnabled = automaticDosingEnabled
        self.isAutomaticDosingAllowed = isAutomaticDosingAllowed
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
