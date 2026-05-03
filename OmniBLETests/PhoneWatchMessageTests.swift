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

    func testCurrentVersionIsFive() {
        XCTAssertEqual(PhoneWatchProtocol.currentVersion, 5,
                       "B.8.2 bumped the protocol version from 4 to 5 to signal the " +
                       "heartbeat encoder dateEncodingStrategy switch (.iso8601 → " +
                       ".secondsSince1970) and applicationContext-delivered " +
                       "AlgorithmStateSnapshot wire format.")
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
        XCTAssertTrue(PhoneWatchProtocol.shouldAccept(incomingVersion: 2))
        XCTAssertTrue(PhoneWatchProtocol.shouldAccept(incomingVersion: 3))
        XCTAssertTrue(PhoneWatchProtocol.shouldAccept(incomingVersion: 4))
        XCTAssertTrue(PhoneWatchProtocol.shouldAccept(incomingVersion: 5),
                      "Current version (5) must accept itself.")
    }

    func testRejectsHigherProtocolVersion() {
        XCTAssertFalse(PhoneWatchProtocol.shouldAccept(incomingVersion: 6))
        XCTAssertFalse(PhoneWatchProtocol.shouldAccept(incomingVersion: 99))
    }

    // MARK: - B.5 Issue #5: claimedOwner field round-trip

    /// Encoding then decoding a heartbeat with claimedOwner set preserves it.
    func testHeartbeat_codable_roundTrip_preservesClaimedOwner() throws {
        let original = PhoneWatchHeartbeat(
            protocolVersion: 3,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            senderRole: .phone,
            appBuildNumber: "861",
            claimedOwner: .phone
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhoneWatchHeartbeat.self, from: data)
        XCTAssertEqual(decoded.claimedOwner, .phone)
        XCTAssertEqual(decoded, original)
    }

    /// A v2-shaped JSON payload (no claimedOwner field) decodes successfully
    /// with claimedOwner = nil. This is the new-receiver-receiving-old-sender case.
    func testHeartbeat_codable_decodesV2Payload_withNilClaimedOwner() throws {
        let v2Json = """
        {
          "protocolVersion": 2,
          "sentAt": 1700000000,
          "senderRole": "phone",
          "appBuildNumber": "860"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PhoneWatchHeartbeat.self, from: v2Json)
        XCTAssertNil(decoded.claimedOwner,
                     "v2 payload (no field) should decode as nil — old sender, new receiver")
    }
}

extension PhoneWatchMessageTests {
    func test_algorithmStateSnapshot_roundTripsViaPhoneWatchMessage() throws {
        let payload = AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            phoneIterationDate: Date(timeIntervalSince1970: 1_700_000_000),
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: PumpStatusSnapshot(
                reservoirUnitsRemaining: 100,
                lastBasalRateUnitsPerHour: 0.5,
                isSuspended: false,
                lastReadingDate: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            activeOverride: nil
        )
        let original: PhoneWatchMessage = .algorithmStateSnapshot(payload)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhoneWatchMessage.self, from: data)
        guard case .algorithmStateSnapshot(let decodedPayload) = decoded else {
            XCTFail("Expected .algorithmStateSnapshot case after round-trip")
            return
        }
        XCTAssertEqual(decodedPayload.snapshotID, payload.snapshotID)
    }
}
