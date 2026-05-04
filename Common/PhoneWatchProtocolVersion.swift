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
    /// B.8.4 (5 → 6): adds `PhoneWatchMessage.algorithmStateSnapshotPointer(sequence:)`.
    /// B.11.0 (6 → 7): adds `PhoneWatchMessage.apnsTokenPublish(APNsTokenPublication)`
    /// for the symmetric APNs-token rendezvous. Old receivers throw on the new
    /// `apnsTokenPublish` Kind raw value before the payload parses.
    public static let currentVersion: Int = 7

    /// True if an incoming message at `incomingVersion` should be accepted.
    public static func shouldAccept(incomingVersion: Int) -> Bool {
        incomingVersion <= currentVersion
    }
}
