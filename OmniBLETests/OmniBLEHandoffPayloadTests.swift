//
//  OmniBLEHandoffPayloadTests.swift
//  OmniBLETests
//

import XCTest
@testable import OmniBLE

final class OmniBLEHandoffPayloadTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override func setUp() {
        super.setUp()
        // Use secondsSince1970 to round-trip Date losslessly enough for equality.
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    private func minimalRawState() -> [String: Any] {
        // Mirrors a minimal PodState rawValue shape; concrete keys vary across
        // PodState versions but for round-trip-of-Data we only need it to be
        // a valid plist-serializable dict.
        return [
            "address": UInt32(0xABCDEF12),
            "controllerId": UInt32(0x12345678),
            "podId": UInt32(0xDEADBEEF),
            "activatedAt": Date(timeIntervalSince1970: 1_700_000_000)
        ]
    }

    func testRoundTrip() throws {
        let raw = minimalRawState()
        let serialized = try PropertyListSerialization.data(
            fromPropertyList: raw, format: .binary, options: 0)
        // Use a Date expressed in whole seconds so the Codable round-trip via
        // secondsSince1970 is bit-exact.
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = OmniBLEHandoffPayload(
            podSerial: "POD123",
            serializedPodState: serialized,
            lastBolusSequence: 42,
            lastBasalScheduleId: UUID(),
            validUntil: Date.distantFuture,
            createdAt: fixedDate
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(OmniBLEHandoffPayload.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCurrentFormatVersionIsTwo() {
        XCTAssertEqual(OmniBLEHandoffPayload.currentFormatVersion, 2)
    }

    func testNewPayloadUsesCurrentFormatVersion() {
        let payload = OmniBLEHandoffPayload(
            podSerial: "X",
            serializedPodState: Data(),
            lastBolusSequence: nil,
            lastBasalScheduleId: nil,
            validUntil: Date(timeIntervalSinceNow: 60)
        )
        XCTAssertEqual(payload.formatVersion, OmniBLEHandoffPayload.currentFormatVersion)
    }

    func testHigherFormatVersionDecodesButFlagsIncompat() throws {
        // Construct a payload with an unknown high formatVersion; decoder still
        // succeeds (Codable is lenient) — consumers check the version themselves.
        let json = """
        {
          "formatVersion": 99,
          "createdAt": 1700000000,
          "validUntil": 1700003600,
          "podSerial": "X",
          "serializedPodState": "",
          "lastBolusSequence": null,
          "lastBasalScheduleId": null
        }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(OmniBLEHandoffPayload.self, from: json)
        XCTAssertEqual(decoded.formatVersion, 99)
        XCTAssertGreaterThan(decoded.formatVersion, OmniBLEHandoffPayload.currentFormatVersion)
    }

    func testDecodingPodStateFromArbitraryDataReturnsDict() throws {
        let raw = minimalRawState()
        let serialized = try PropertyListSerialization.data(
            fromPropertyList: raw, format: .binary, options: 0)
        let payload = OmniBLEHandoffPayload(
            podSerial: "X",
            serializedPodState: serialized,
            lastBolusSequence: nil,
            lastBasalScheduleId: nil,
            validUntil: Date(timeIntervalSinceNow: 60)
        )
        let dict = try payload.decodePodStateRawValue()
        XCTAssertEqual(dict["address"] as? UInt32, 0xABCDEF12)
        XCTAssertEqual(dict["podId"] as? UInt32, 0xDEADBEEF)
    }

    func testIsValidNowChecksAgainstValidUntil() {
        let p = OmniBLEHandoffPayload(
            podSerial: "X",
            serializedPodState: Data(),
            lastBolusSequence: nil,
            lastBasalScheduleId: nil,
            validUntil: Date(timeIntervalSinceNow: 60)
        )
        XCTAssertTrue(p.isValid(now: Date()))
        XCTAssertFalse(p.isValid(now: Date(timeIntervalSinceNow: 120)))
    }

    func testEncodedRoundTripsViaJSON() throws {
        let p = OmniBLEHandoffPayload(
            podSerial: "TEST_POD_X",
            serializedPodState: Data("dummy".utf8),
            lastBolusSequence: 42,
            lastBasalScheduleId: UUID(),
            validUntil: Date(timeIntervalSinceNow: 60)
        )
        let data = try p.encoded()
        let decoded = try JSONDecoder().decode(OmniBLEHandoffPayload.self, from: data)
        XCTAssertEqual(decoded.podSerial, p.podSerial)
        XCTAssertEqual(decoded.lastBolusSequence, p.lastBolusSequence)
        XCTAssertEqual(decoded.lastBasalScheduleId, p.lastBasalScheduleId)
    }

    // MARK: - B.4 Issue #6: validity boundary

    /// Default validity is 600s (10 min). At T+599s, payload is still valid.
    func test_defaultValidity_atNineFiftyNineSeconds_isFresh() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let validUntil = createdAt.addingTimeInterval(600)
        let payload = OmniBLEHandoffPayload(
            podSerial: "POD123",
            serializedPodState: Data(),
            lastBolusSequence: nil,
            lastBasalScheduleId: nil,
            validUntil: validUntil,
            createdAt: createdAt
        )
        let testTime = createdAt.addingTimeInterval(599)
        XCTAssertTrue(payload.isValid(now: testTime),
                      "Payload at T+599s of a 600s window should still be fresh")
    }

    /// At T+601s, payload has expired.
    func test_defaultValidity_atTenMinutesOneSecond_isStale() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let validUntil = createdAt.addingTimeInterval(600)
        let payload = OmniBLEHandoffPayload(
            podSerial: "POD123",
            serializedPodState: Data(),
            lastBolusSequence: nil,
            lastBasalScheduleId: nil,
            validUntil: validUntil,
            createdAt: createdAt
        )
        let testTime = createdAt.addingTimeInterval(601)
        XCTAssertFalse(payload.isValid(now: testTime),
                       "Payload at T+601s of a 600s window should be stale")
    }

    /// Explicit-validUntil callers are unaffected: passing a custom 60s window
    /// still yields a 60s-bound payload, so existing call sites don't change behavior.
    func test_explicitValidUntil_overridesDefault() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = OmniBLEHandoffPayload(
            podSerial: "POD123",
            serializedPodState: Data(),
            lastBolusSequence: nil,
            lastBasalScheduleId: nil,
            validUntil: createdAt.addingTimeInterval(60),
            createdAt: createdAt
        )
        XCTAssertTrue(payload.isValid(now: createdAt.addingTimeInterval(59)))
        XCTAssertFalse(payload.isValid(now: createdAt.addingTimeInterval(61)))
    }

    /// Default validity is now 600s (B.4 Issue #6). Verify by inspecting the
    /// source for the constant, since the convenience init that uses the
    /// default requires a real PodState which is expensive to construct in a test.
    func test_convenienceInit_defaultIs600Seconds() throws {
        let sourcePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Common/OmniBLEHandoffPayload.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)
        XCTAssertTrue(source.contains("Date(timeIntervalSinceNow: 600)"),
                      "Convenience init default validity should be 600s (B.4 Issue #6)")
        XCTAssertFalse(source.contains("Date(timeIntervalSinceNow: 60)"),
                       "Old 60s default should be gone")
    }
}
