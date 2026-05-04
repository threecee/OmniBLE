//
//  DriverTokenRendezvous.swift
//  OmniBLE
//
//  B.11.2: caretaker-app discovery payload published in Nightscout
//  devicestatus. The current driver writes both devices' APNs tokens +
//  a currentDriver indicator + an HMAC-SHA256 signature over a
//  deterministic byte sequence using the Nightscout API secret as the
//  signing key. Caretaker apps verify the signature, then route remote
//  commands at the currentDriver's token.
//
//  JSON path note: in B.11.2 the rendezvous lands at
//  `loop.testingDetails.driverToken` rather than `loop.driverToken` —
//  `LoopStatus` is defined in the external NightscoutKit SwiftPM
//  package and adding a sibling key under `loop` would require forking
//  it. Riding `testingDetails: [String: Any]?` (an existing free-form
//  field on LoopStatus) is the smallest-blast-radius splice. The signed
//  payload semantics are unchanged; caretaker apps look one nesting
//  level deeper.
//
//  Driver-only-writes invariant (per B.11 spec §Architecture): only the
//  device that is the current BLE driver constructs and uploads this
//  rendezvous. Passenger never writes.
//
//  Token freshness: caretaker apps treat any TokenEntry whose lastSeen
//  is > 3600s old as stale and fall back to the QR-captured phone
//  token. The driver refreshes lastSeen on every iteration (~5 min
//  cadence).
//

import Foundation
import CryptoKit

public struct DriverTokenRendezvous: Codable, Equatable {

    public struct TokenEntry: Codable, Equatable {
        public let token: String      // base64
        public let expiresAt: Date
        public let lastSeen: Date

        public init(token: String, expiresAt: Date, lastSeen: Date) {
            self.token = token
            self.expiresAt = expiresAt
            self.lastSeen = lastSeen
        }

        /// Caretaker-side staleness check. A token whose lastSeen is older
        /// than `staleThreshold` (default 1 hour) should not be trusted as
        /// the current driver's APNs target. Spec §B.11.2 freshness rule.
        public static let staleThreshold: TimeInterval = 3600

        public func isStale(asOf now: Date = Date()) -> Bool {
            now.timeIntervalSince(lastSeen) > Self.staleThreshold
        }
    }

    public enum DriverIndicator: String, Codable, Equatable {
        case phone
        case watch

        public init(role: HandoffRole) {
            switch role {
            case .phone: self = .phone
            case .watch: self = .watch
            }
        }
    }

    public let phone: TokenEntry
    public let watch: TokenEntry
    public let currentDriver: DriverIndicator
    public let timestamp: Date
    public let signature: String  // base64 of HMAC-SHA256 output

    public init(phone: TokenEntry,
                watch: TokenEntry,
                currentDriver: DriverIndicator,
                timestamp: Date,
                signature: String) {
        self.phone = phone
        self.watch = watch
        self.currentDriver = currentDriver
        self.timestamp = timestamp
        self.signature = signature
    }

    /// Deterministic byte sequence over which the HMAC is computed.
    /// Format: `phone.token|watch.token|currentDriver|timestamp_iso8601`.
    /// Stable across encoders (does not depend on JSON key ordering).
    /// Spec §B.11.2: "HMAC-SHA256 of {phone.token, watch.token,
    /// currentDriver, timestamp} using Nightscout API secret".
    internal static func canonicalMessage(phoneToken: String,
                                          watchToken: String,
                                          currentDriver: DriverIndicator,
                                          timestamp: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: timestamp)
        let s = "\(phoneToken)|\(watchToken)|\(currentDriver.rawValue)|\(stamp)"
        return Data(s.utf8)
    }

    /// Returns a copy with `signature` populated by HMAC-SHA256 over the
    /// canonical message using `apiSecret` as the symmetric key.
    /// If `apiSecret` is empty, signature is the empty string — caretaker
    /// apps then have weaker tampering protection (spec §Risks #4); the
    /// iOS app surfaces a UI warning when this state co-occurs with
    /// watch-driving.
    public func signed(with apiSecret: String) -> DriverTokenRendezvous {
        guard !apiSecret.isEmpty else {
            return DriverTokenRendezvous(
                phone: phone,
                watch: watch,
                currentDriver: currentDriver,
                timestamp: timestamp,
                signature: ""
            )
        }
        let message = Self.canonicalMessage(
            phoneToken: phone.token,
            watchToken: watch.token,
            currentDriver: currentDriver,
            timestamp: timestamp
        )
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        let signatureB64 = Data(mac).base64EncodedString()
        return DriverTokenRendezvous(
            phone: phone,
            watch: watch,
            currentDriver: currentDriver,
            timestamp: timestamp,
            signature: signatureB64
        )
    }

    /// Constant-time signature verification. Returns true iff `signature`
    /// equals HMAC-SHA256(canonicalMessage, apiSecret). Caretaker-side
    /// validators use this before trusting the currentDriver indicator.
    public func verify(with apiSecret: String) -> Bool {
        guard !apiSecret.isEmpty, !signature.isEmpty else { return false }
        guard let provided = Data(base64Encoded: signature) else { return false }
        let message = Self.canonicalMessage(
            phoneToken: phone.token,
            watchToken: watch.token,
            currentDriver: currentDriver,
            timestamp: timestamp
        )
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(provided,
                                                     authenticating: message,
                                                     using: key)
    }

    /// Free-form `[String: Any]` representation for embedding into
    /// `LoopStatus.testingDetails["driverToken"]`. ISO8601 timestamps so
    /// caretaker apps can parse without extra schema knowledge. The
    /// signature is the same base64 string the verify path expects.
    public var dictionaryRepresentation: [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return [
            "phone": [
                "token": phone.token,
                "expiresAt": formatter.string(from: phone.expiresAt),
                "lastSeen": formatter.string(from: phone.lastSeen),
            ],
            "watch": [
                "token": watch.token,
                "expiresAt": formatter.string(from: watch.expiresAt),
                "lastSeen": formatter.string(from: watch.lastSeen),
            ],
            "currentDriver": currentDriver.rawValue,
            "timestamp": formatter.string(from: timestamp),
            "signature": signature,
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case phone, watch, currentDriver, timestamp, signature
    }
}
