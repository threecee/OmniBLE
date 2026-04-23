//
//  HandoffMode.swift
//  OmniBLE
//
//  User-selectable policy for when bonding handoffs may happen automatically.
//  Stored in HandoffSettings.
//

import Foundation

public enum HandoffMode: String, Codable, Equatable, CaseIterable {
    /// Manual triggers only. Automatic policy engine emits no events.
    case manual

    /// Manual triggers; automatic revert when phone returns reachable.
    case manualWithAutoRevert

    /// Fully automatic in both directions.
    case automatic

    public var allowsAutomaticTakeover: Bool {
        self == .automatic
    }

    public var allowsAutomaticRevert: Bool {
        self == .automatic || self == .manualWithAutoRevert
    }
}
