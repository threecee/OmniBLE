//
//  PhoneWatchHeartbeat.swift
//  OmniBLE
//
//  Periodic liveness message exchanged between phone and watch every ~30 seconds
//  while both apps are reachable. Used to detect connection loss; also carries
//  a diagnostic appBuildNumber for version-skew visibility.
//

import Foundation

public enum PhoneWatchSenderRole: String, Codable, Equatable {
    case phone
    case watch
}

public struct PhoneWatchHeartbeat: Codable, Equatable {
    public let protocolVersion: Int
    public let sentAt: Date
    public let senderRole: PhoneWatchSenderRole
    public let appBuildNumber: String

    /// B.5 Issue #5: who the sender currently believes is the pod owner.
    /// Optional + nil-default for backward compatibility with v2 senders;
    /// receivers use this for split-brain detection (phone-wins arbitration).
    public let claimedOwner: HandoffOwner?

    public init(protocolVersion: Int,
                sentAt: Date,
                senderRole: PhoneWatchSenderRole,
                appBuildNumber: String,
                claimedOwner: HandoffOwner? = nil) {
        self.protocolVersion = protocolVersion
        self.sentAt = sentAt
        self.senderRole = senderRole
        self.appBuildNumber = appBuildNumber
        self.claimedOwner = claimedOwner
    }
}
