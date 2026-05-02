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

    // MARK: - B.4 Issue #3: automaticDosing field round-trip

    /// Encoding then decoding a sync with both flags set preserves their values.
    func testCodableRoundTripPreservesAutomaticDosingFlags() throws {
        let original = PhoneWatchSettingsSync(
            protocolVersion: 2,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            basalScheduleItems: [],
            insulinSensitivityScheduleItems: [],
            carbRatioScheduleItems: [],
            glucoseTargetRangeScheduleItems: [],
            maximumBolusUnits: 10,
            maximumBasalRatePerHourUnits: 4,
            suspendThresholdMgdL: 72,
            nightscoutConfig: nil,
            automaticDosingEnabled: true,
            isAutomaticDosingAllowed: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhoneWatchSettingsSync.self, from: data)
        XCTAssertEqual(decoded.automaticDosingEnabled, true)
        XCTAssertEqual(decoded.isAutomaticDosingAllowed, true)
        XCTAssertEqual(decoded, original)
    }

    /// A v1-shaped JSON payload (no new fields present) decodes successfully
    /// with both flags = nil. This is the new-watch-receiving-old-phone case.
    func testCodableDecodesV1PayloadWithNilAutomaticDosingFlags() throws {
        let v1Json = """
        {
          "protocolVersion": 1,
          "sentAt": 1700000000,
          "basalScheduleItems": [],
          "insulinSensitivityScheduleItems": [],
          "carbRatioScheduleItems": [],
          "glucoseTargetRangeScheduleItems": [],
          "maximumBolusUnits": 10,
          "maximumBasalRatePerHourUnits": 4,
          "suspendThresholdMgdL": 72,
          "nightscoutConfig": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PhoneWatchSettingsSync.self, from: v1Json)
        XCTAssertNil(decoded.automaticDosingEnabled,
                     "v1 payload (no field) should decode as nil — old phone, new watch")
        XCTAssertNil(decoded.isAutomaticDosingAllowed,
                     "v1 payload (no field) should decode as nil — old phone, new watch")
    }

    /// A v2-shaped JSON payload with both flags set decodes correctly.
    func testCodableProtocolVersion2DecodesCleanly() throws {
        let v2Json = """
        {
          "protocolVersion": 2,
          "sentAt": 1700000000,
          "basalScheduleItems": [],
          "insulinSensitivityScheduleItems": [],
          "carbRatioScheduleItems": [],
          "glucoseTargetRangeScheduleItems": [],
          "maximumBolusUnits": 10,
          "maximumBasalRatePerHourUnits": 4,
          "suspendThresholdMgdL": 72,
          "nightscoutConfig": null,
          "automaticDosingEnabled": true,
          "isAutomaticDosingAllowed": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PhoneWatchSettingsSync.self, from: v2Json)
        XCTAssertEqual(decoded.protocolVersion, 2)
        XCTAssertEqual(decoded.automaticDosingEnabled, true)
        XCTAssertEqual(decoded.isAutomaticDosingAllowed, false)
    }

    // MARK: - B.5.2 Issue #3: timeZone field round-trip

    /// Encoding then decoding a sync with timeZone set preserves the identifier.
    func testTimeZoneRoundTripsThroughCodable() throws {
        let original = PhoneWatchSettingsSync(
            protocolVersion: 4,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            basalScheduleItems: [],
            insulinSensitivityScheduleItems: [],
            carbRatioScheduleItems: [],
            glucoseTargetRangeScheduleItems: [],
            maximumBolusUnits: 10,
            maximumBasalRatePerHourUnits: 4,
            suspendThresholdMgdL: 72,
            nightscoutConfig: nil,
            automaticDosingEnabled: true,
            isAutomaticDosingAllowed: true,
            timeZone: "Europe/Copenhagen"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhoneWatchSettingsSync.self, from: data)
        XCTAssertEqual(decoded.timeZone, "Europe/Copenhagen")
        XCTAssertEqual(decoded, original)
    }

    /// A v3-shaped JSON payload (no timeZone field) decodes successfully
    /// with timeZone = nil. This is the new-watch-receiving-old-phone case.
    func testCodableV3PayloadDecodesWithNilTimeZone() throws {
        let v3Json = """
        {
          "protocolVersion": 3,
          "sentAt": 1700000000,
          "basalScheduleItems": [],
          "insulinSensitivityScheduleItems": [],
          "carbRatioScheduleItems": [],
          "glucoseTargetRangeScheduleItems": [],
          "maximumBolusUnits": 10,
          "maximumBasalRatePerHourUnits": 4,
          "suspendThresholdMgdL": 72,
          "nightscoutConfig": null,
          "automaticDosingEnabled": true,
          "isAutomaticDosingAllowed": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PhoneWatchSettingsSync.self, from: v3Json)
        XCTAssertNil(decoded.timeZone,
                     "v3 payload (no field) should decode as nil — old phone, new watch")
    }
}
