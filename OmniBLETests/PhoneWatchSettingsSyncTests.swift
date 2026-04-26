//
//  PhoneWatchSettingsSyncTests.swift
//  OmniBLETests
//

import XCTest
import LoopKit
@testable import OmniBLE

final class PhoneWatchSettingsSyncTests: XCTestCase {

    func testSettingsSyncRoundTripsThroughCodable() throws {
        let original = PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            basalScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: 0.5),
                RepeatingScheduleValue(startTime: 21600, value: 0.7),
                RepeatingScheduleValue(startTime: 43200, value: 0.5)
            ],
            insulinSensitivityScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: 50.0)
            ],
            carbRatioScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: 12.0)
            ],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: 10.0,
            maximumBasalRatePerHourUnits: 4.0,
            suspendThresholdMgdL: 70,
            nightscoutConfig: PhoneWatchSettingsSync.NightscoutConfig(
                url: URL(string: "https://example-ns.test")!,
                apiSecret: "test-secret-not-real"
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhoneWatchSettingsSync.self, from: data)

        XCTAssertEqual(decoded.protocolVersion, original.protocolVersion)
        XCTAssertEqual(decoded.sentAt.timeIntervalSince1970, original.sentAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.basalScheduleItems.count, 3)
        XCTAssertEqual(decoded.basalScheduleItems[1].value, 0.7, accuracy: 0.001)
        XCTAssertEqual(decoded.maximumBolusUnits, 10.0)
        XCTAssertEqual(decoded.maximumBasalRatePerHourUnits, 4.0)
        XCTAssertEqual(decoded.suspendThresholdMgdL, 70)
        XCTAssertEqual(decoded.nightscoutConfig?.url.absoluteString, "https://example-ns.test")
        XCTAssertEqual(decoded.nightscoutConfig?.apiSecret, "test-secret-not-real")
    }

    func testSettingsSyncWithoutNightscoutConfig() throws {
        let original = PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 0.5)],
            insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 12.0)],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: 10.0,
            maximumBasalRatePerHourUnits: 4.0,
            suspendThresholdMgdL: nil,
            nightscoutConfig: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhoneWatchSettingsSync.self, from: data)
        XCTAssertNil(decoded.nightscoutConfig)
        XCTAssertNil(decoded.suspendThresholdMgdL)
    }
}
