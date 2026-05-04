//
//  APNsTokenPublication.swift
//  OmniBLE
//
//  Wire-format payload for the B.11.0 `apnsTokenPublish` PhoneWatchMessage
//  case. Each device publishes its own APNs device token (and the OS-stamped
//  expiration) to the counterpart over WCSession on receipt of the
//  `didRegisterForRemoteNotifications` callback. Both sides persist their
//  own + the counterpart's token to the shared App Group via
//  `HandoffSettings.appGroupDefaults` so the driver-owns-network logic
//  (B.11.1+) can read either token by role.
//

import Foundation

public struct APNsTokenPublication: Codable, Equatable {
    /// Wire-format protocol version. Encoded under `protocolVersion` so older
    /// receivers can short-circuit on version-mismatch (see
    /// `PhoneWatchProtocol.shouldAccept(incomingVersion:)`).
    public let protocolVersion: Int
    /// Wall-clock send time. Used for log diagnostics; not for liveness.
    public let sentAt: Date
    /// Whose token this is. `.phone` from iOS app; `.watch` from WatchApp Extension.
    public let role: HandoffRole
    /// The raw APNs device token bytes from
    /// `didRegisterForRemoteNotificationsWithDeviceToken`. Encoded as
    /// base64 by `Data`'s default Codable conformance.
    public let token: Data
    /// Best-effort expiration. Apple does not publish a hard token TTL;
    /// callers conventionally set `Date().addingTimeInterval(60 * 60 * 24 * 30)`
    /// (30 days) and re-publish on each registration callback. Treated as a
    /// staleness hint by future driver-token consumers (B.11.2).
    public let expiresAt: Date

    public init(protocolVersion: Int,
                sentAt: Date,
                role: HandoffRole,
                token: Data,
                expiresAt: Date) {
        self.protocolVersion = protocolVersion
        self.sentAt = sentAt
        self.role = role
        self.token = token
        self.expiresAt = expiresAt
    }
}
