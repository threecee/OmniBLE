//
//  PhoneWatchProtocolVersion.swift
//  OmniBLE
//
//  Version-negotiation constants for the phone↔watch WCSession protocol.
//  Receivers accept messages at the current version or lower (forward-compatible:
//  older sender, newer receiver). Receivers REJECT messages at a higher version
//  they don't understand.
//

import Foundation

public enum PhoneWatchProtocol {
    /// Bumped on any incompatible change to message shapes or transport conventions.
    public static let currentVersion: Int = 2

    /// True if an incoming message at `incomingVersion` should be accepted.
    public static func shouldAccept(incomingVersion: Int) -> Bool {
        incomingVersion <= currentVersion
    }
}
