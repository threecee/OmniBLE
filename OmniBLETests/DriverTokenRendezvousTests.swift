//
//  DriverTokenRendezvousTests.swift
//  OmniBLETests
//
//  B.11.2: signing roundtrip + verification + Codable shape.
//

import XCTest
@testable import OmniBLE

final class DriverTokenRendezvousTests: XCTestCase {

    private let phoneToken = DriverTokenRendezvous.TokenEntry(
        token: "cGhvbmUtdG9rZW4=",  // base64("phone-token")
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        lastSeen: Date(timeIntervalSince1970: 1_999_999_500)
    )
    private let watchToken = DriverTokenRendezvous.TokenEntry(
        token: "d2F0Y2gtdG9rZW4=",  // base64("watch-token")
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        lastSeen: Date(timeIntervalSince1970: 1_999_999_500)
    )

    func test_signature_verification_roundtrip_succeeds_with_same_secret() {
        let unsigned = DriverTokenRendezvous(
            phone: phoneToken,
            watch: watchToken,
            currentDriver: .phone,
            timestamp: Date(timeIntervalSince1970: 1_999_999_500),
            signature: ""
        )
        let signed = unsigned.signed(with: "shared-secret")
        XCTAssertFalse(signed.signature.isEmpty)
        XCTAssertTrue(signed.verify(with: "shared-secret"))
    }

    func test_signature_verification_fails_with_wrong_secret() {
        let unsigned = DriverTokenRendezvous(
            phone: phoneToken,
            watch: watchToken,
            currentDriver: .phone,
            timestamp: Date(timeIntervalSince1970: 1_999_999_500),
            signature: ""
        )
        let signed = unsigned.signed(with: "shared-secret")
        XCTAssertFalse(signed.verify(with: "different-secret"))
    }

    func test_signature_is_deterministic_for_same_input() {
        let unsigned = DriverTokenRendezvous(
            phone: phoneToken,
            watch: watchToken,
            currentDriver: .watch,
            timestamp: Date(timeIntervalSince1970: 1_999_999_500),
            signature: ""
        )
        let a = unsigned.signed(with: "shared-secret")
        let b = unsigned.signed(with: "shared-secret")
        XCTAssertEqual(a.signature, b.signature)
    }

    func test_currentDriver_change_changes_signature() {
        let phoneSigned = DriverTokenRendezvous(
            phone: phoneToken,
            watch: watchToken,
            currentDriver: .phone,
            timestamp: Date(timeIntervalSince1970: 1_999_999_500),
            signature: ""
        ).signed(with: "shared-secret")
        let watchSigned = DriverTokenRendezvous(
            phone: phoneToken,
            watch: watchToken,
            currentDriver: .watch,
            timestamp: Date(timeIntervalSince1970: 1_999_999_500),
            signature: ""
        ).signed(with: "shared-secret")
        XCTAssertNotEqual(phoneSigned.signature, watchSigned.signature)
    }

    func test_codable_roundtrip_preserves_all_fields() throws {
        let signed = DriverTokenRendezvous(
            phone: phoneToken,
            watch: watchToken,
            currentDriver: .phone,
            timestamp: Date(timeIntervalSince1970: 1_999_999_500),
            signature: ""
        ).signed(with: "shared-secret")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(signed)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DriverTokenRendezvous.self, from: data)
        XCTAssertEqual(decoded, signed)
        XCTAssertTrue(decoded.verify(with: "shared-secret"))
    }

    func test_stale_token_detection_lastSeen_older_than_one_hour() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let staleEntry = DriverTokenRendezvous.TokenEntry(
            token: "cGhvbmU=",
            expiresAt: now.addingTimeInterval(86_400),
            lastSeen: now.addingTimeInterval(-3601)  // 1 hour 1 second old
        )
        let freshEntry = DriverTokenRendezvous.TokenEntry(
            token: "d2F0Y2g=",
            expiresAt: now.addingTimeInterval(86_400),
            lastSeen: now.addingTimeInterval(-60)
        )
        XCTAssertTrue(staleEntry.isStale(asOf: now))
        XCTAssertFalse(freshEntry.isStale(asOf: now))
    }

    func test_stale_token_at_exactly_one_hour_is_not_stale() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let edgeEntry = DriverTokenRendezvous.TokenEntry(
            token: "cGhvbmU=",
            expiresAt: now.addingTimeInterval(86_400),
            lastSeen: now.addingTimeInterval(-3600)  // exactly 1 hour old
        )
        XCTAssertFalse(edgeEntry.isStale(asOf: now))
    }

    func test_dictionary_representation_includes_all_fields() throws {
        let signed = DriverTokenRendezvous(
            phone: phoneToken,
            watch: watchToken,
            currentDriver: .watch,
            timestamp: Date(timeIntervalSince1970: 1_999_999_500),
            signature: ""
        ).signed(with: "k")
        let dict = signed.dictionaryRepresentation
        XCTAssertEqual(dict["currentDriver"] as? String, "watch")
        XCTAssertNotNil(dict["phone"])
        XCTAssertNotNil(dict["watch"])
        XCTAssertNotNil(dict["timestamp"])
        XCTAssertNotNil(dict["signature"])
        XCTAssertFalse((dict["signature"] as? String ?? "").isEmpty)
        let phoneDict = try XCTUnwrap(dict["phone"] as? [String: Any])
        XCTAssertEqual(phoneDict["token"] as? String, "cGhvbmUtdG9rZW4=")
    }

    func test_empty_secret_yields_empty_signature_and_verify_false() {
        let signed = DriverTokenRendezvous(
            phone: phoneToken,
            watch: watchToken,
            currentDriver: .phone,
            timestamp: Date(timeIntervalSince1970: 1_999_999_500),
            signature: ""
        ).signed(with: "")
        XCTAssertEqual(signed.signature, "")
        XCTAssertFalse(signed.verify(with: ""))
        XCTAssertFalse(signed.verify(with: "anything"))
    }
}
