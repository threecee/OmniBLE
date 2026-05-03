//
//  UserDefaults+Codable.swift
//  OmniBLE (Common)
//
//  B.8.1 mechanical /simplify: Codable get/set helpers on UserDefaults.
//  Replaces verbatim `try? JSONEncoder().encode(...) + defaults.set` and
//  `defaults.data(forKey:) + try? JSONDecoder().decode(...)` patterns in
//  OmniBLEOwnership, WatchAlgorithmSnapshotCache, WatchDoseRecoveryStore.
//  No behavioral change.
//
//  Note: callsites that intentionally use a `do/catch` with explicit error
//  logging (HandoffStatePersistence.save/load, HandoffSettings.save) or
//  that serialize a non-defaults wire format (BLE payloads, WCSession
//  message decoders) deliberately do NOT use this extension — losing the
//  error path there would erase a safety-relevant log line.
//

import Foundation

public extension UserDefaults {
    /// Encodes a Codable value as JSON and writes it under the given key.
    /// Encoding failures are silently swallowed to match the existing
    /// `try? JSONEncoder().encode(...)` pattern these helpers replace.
    /// Use this only at sites where a silent failure is acceptable.
    func set<T: Codable>(codable value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            set(data, forKey: key)
        }
    }

    /// Reads JSON Data under the key and decodes it as the given Codable
    /// type. Returns nil for missing keys, decode failures, or empty data —
    /// matches the existing `try? JSONDecoder().decode(...)` pattern.
    func codableValue<T: Codable>(forKey key: String, as type: T.Type) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
