//
//  HandoffOwner.swift
//  OmniBLE
//
//  Identity for which side currently owns (or last owned) the pod's
//  BLE bonding session. Used by HandoffStateMachine and surfaced in UI.
//

import Foundation

public enum HandoffOwner: String, Codable, Equatable, CaseIterable {
    case phone
    case watch
}
