//
//  PhoneWatchMessageTests.swift
//  OmniBLETests
//
//  Codable round-trip + equality + version-negotiation tests for the phone↔watch
//  WCSession message types defined in OmniBLE/Common/.
//

import XCTest
@testable import OmniBLE

final class PhoneWatchMessageTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override func setUp() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Protocol version

    func testCurrentVersionIsTwo() {
        XCTAssertEqual(PhoneWatchProtocol.currentVersion, 2,
                       "B.4 Issue #3 bumped the protocol version from 1 to 2 to signal " +
                       "the new automaticDosingEnabled / isAutomaticDosingAllowed fields.")
    }

    // MARK: - Heartbeat

    func testHeartbeatRoundTrip() throws {
        let original = PhoneWatchHeartbeat(
            protocolVersion: 1,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            senderRole: .phone,
            appBuildNumber: "42"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PhoneWatchHeartbeat.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Mode switch

    func testModeSwitchRoundTrip() throws {
        let id = UUID()
        let original = PhoneWatchModeSwitch(
            protocolVersion: 1,
            sentAt: Date(timeIntervalSince1970: 1_700_000_100),
            requestedBy: .watch,
            targetMode: .watchDriver,
            transitionId: id
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PhoneWatchModeSwitch.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPodOwnershipValues() {
        XCTAssertEqual(PhoneWatchPodOwnership.phoneDriver.rawValue, "phoneDriver")
        XCTAssertEqual(PhoneWatchPodOwnership.watchDriver.rawValue, "watchDriver")
        XCTAssertEqual(PhoneWatchPodOwnership.neither.rawValue, "neither")
    }

    // MARK: - Pairing handoff

    func testPairingHandoffRoundTrip() throws {
        let id = UUID()
        let original = PhoneWatchPairingHandoff(
            protocolVersion: 1,
            sentAt: Date(timeIntervalSince1970: 1_700_000_200),
            podId: "POD123",
            pairingPayload: Data([0x01, 0x02, 0x03]),
            validUntil: Date(timeIntervalSince1970: 1_700_000_260),
            transitionId: id
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PhoneWatchPairingHandoff.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Wrapped message

    func testWrappedHeartbeatRoundTrip() throws {
        let hb = PhoneWatchHeartbeat(
            protocolVersion: 1, sentAt: Date(timeIntervalSince1970: 1_700_000_300),
            senderRole: .phone, appBuildNumber: "1"
        )
        let original = PhoneWatchMessage.heartbeat(hb)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PhoneWatchMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testWrappedModeSwitchRoundTrip() throws {
        let ms = PhoneWatchModeSwitch(
            protocolVersion: 1, sentAt: Date(timeIntervalSince1970: 1_700_000_400),
            requestedBy: .phone, targetMode: .neither, transitionId: UUID()
        )
        let original = PhoneWatchMessage.modeSwitch(ms)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PhoneWatchMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testWrappedPairingHandoffRoundTrip() throws {
        let ph = PhoneWatchPairingHandoff(
            protocolVersion: 1, sentAt: Date(timeIntervalSince1970: 1_700_000_500),
            podId: "X", pairingPayload: Data(), validUntil: Date(timeIntervalSince1970: 1_700_000_560),
            transitionId: UUID()
        )
        let original = PhoneWatchMessage.pairingHandoff(ph)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PhoneWatchMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Version negotiation

    func testAcceptsLowerOrCurrentProtocolVersion() {
        XCTAssertTrue(PhoneWatchProtocol.shouldAccept(incomingVersion: 0))
        XCTAssertTrue(PhoneWatchProtocol.shouldAccept(incomingVersion: 1))
        XCTAssertTrue(PhoneWatchProtocol.shouldAccept(incomingVersion: 2),
                      "Current version (2) must accept itself.")
    }

    func testRejectsHigherProtocolVersion() {
        XCTAssertFalse(PhoneWatchProtocol.shouldAccept(incomingVersion: 3))
        XCTAssertFalse(PhoneWatchProtocol.shouldAccept(incomingVersion: 99))
    }
}
