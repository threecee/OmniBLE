//
//  PhoneWatchMessage.swift
//  OmniBLE
//
//  Top-level discriminating enum that wraps the three phone↔watch message types.
//  WCSession-level transport encodes/decodes this enum; receivers pattern-match
//  to dispatch to their type-specific handlers.
//

import Foundation

public enum PhoneWatchMessage: Codable, Equatable {
    case heartbeat(PhoneWatchHeartbeat)
    case modeSwitch(PhoneWatchModeSwitch)
    case pairingHandoff(PhoneWatchPairingHandoff)
    /// B.3.a Phase 6: phone → watch settings synchronization.
    case settingsSync(PhoneWatchSettingsSync)
    /// phone → watch algorithm-state snapshot (every iteration).
    case algorithmStateSnapshot(AlgorithmStateSnapshot)
    /// tiny pointer message used when the actual snapshot payload
    /// exceeds the applicationContext size budget. The watch reads the
    /// payload from <AppGroup>/snapshot.json on receipt of this message.
    /// The sequence number monotonically increases per emission; older
    /// sequences are ignored on receipt (the receiver compares against
    /// the highest-seen sequence).
    case algorithmStateSnapshotPointer(sequence: UInt64)

    // MARK: Codable (manual implementation — Swift's automatic enum Codable
    // uses a structure we want to pin explicitly for transport stability).

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private enum Kind: String, Codable {
        case heartbeat
        case modeSwitch
        case pairingHandoff
        case settingsSync
        case algorithmStateSnapshot
        case algorithmStateSnapshotPointer
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .heartbeat(let h):
            try container.encode(Kind.heartbeat, forKey: .kind)
            try container.encode(h, forKey: .payload)
        case .modeSwitch(let m):
            try container.encode(Kind.modeSwitch, forKey: .kind)
            try container.encode(m, forKey: .payload)
        case .pairingHandoff(let p):
            try container.encode(Kind.pairingHandoff, forKey: .kind)
            try container.encode(p, forKey: .payload)
        case .settingsSync(let s):
            try container.encode(Kind.settingsSync, forKey: .kind)
            try container.encode(s, forKey: .payload)
        case .algorithmStateSnapshot(let s):
            try container.encode(Kind.algorithmStateSnapshot, forKey: .kind)
            try container.encode(s, forKey: .payload)
        case .algorithmStateSnapshotPointer(let sequence):
            try container.encode(Kind.algorithmStateSnapshotPointer, forKey: .kind)
            try container.encode(sequence, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .heartbeat:
            self = .heartbeat(try container.decode(PhoneWatchHeartbeat.self, forKey: .payload))
        case .modeSwitch:
            self = .modeSwitch(try container.decode(PhoneWatchModeSwitch.self, forKey: .payload))
        case .pairingHandoff:
            self = .pairingHandoff(try container.decode(PhoneWatchPairingHandoff.self, forKey: .payload))
        case .settingsSync:
            self = .settingsSync(try container.decode(PhoneWatchSettingsSync.self, forKey: .payload))
        case .algorithmStateSnapshot:
            self = .algorithmStateSnapshot(try container.decode(AlgorithmStateSnapshot.self, forKey: .payload))
        case .algorithmStateSnapshotPointer:
            self = .algorithmStateSnapshotPointer(sequence: try container.decode(UInt64.self, forKey: .payload))
        }
    }
}
