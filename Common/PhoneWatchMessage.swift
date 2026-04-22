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
        }
    }
}
