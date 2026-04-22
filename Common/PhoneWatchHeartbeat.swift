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

    public init(protocolVersion: Int, sentAt: Date, senderRole: PhoneWatchSenderRole, appBuildNumber: String) {
        self.protocolVersion = protocolVersion
        self.sentAt = sentAt
        self.senderRole = senderRole
        self.appBuildNumber = appBuildNumber
    }
}
