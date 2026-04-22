//
//  PhoneWatchModeSwitch.swift
//  OmniBLE
//
//  Request to transition pod-ownership between phone-driver and watch-driver
//  modes. Carries a transitionId for idempotency across retries. The receiver
//  is responsible for deciding whether to honor the request; B.2.c stubs it.
//

import Foundation

public enum PhoneWatchPodOwnership: String, Codable, Equatable {
    case phoneDriver
    case watchDriver
    case neither
}

public struct PhoneWatchModeSwitch: Codable, Equatable {
    public let protocolVersion: Int
    public let sentAt: Date
    public let requestedBy: PhoneWatchSenderRole
    public let targetMode: PhoneWatchPodOwnership
    public let transitionId: UUID

    public init(protocolVersion: Int, sentAt: Date, requestedBy: PhoneWatchSenderRole,
                targetMode: PhoneWatchPodOwnership, transitionId: UUID) {
        self.protocolVersion = protocolVersion
        self.sentAt = sentAt
        self.requestedBy = requestedBy
        self.targetMode = targetMode
        self.transitionId = transitionId
    }
}
