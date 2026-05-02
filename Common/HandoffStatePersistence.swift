//
//  HandoffStatePersistence.swift
//  OmniBLE (Common)
//
//  B.5 Issue #4: persists HandoffState to App Group UserDefaults so the
//  state machine can recover from app crashes mid-handoff.
//
//  Uses a versioned wrapper (formatVersion: Int) so future state-machine
//  evolutions can reject incompatible saved states by bumping the
//  expected version.
//

import Foundation
import os.log

/// Wrapper that pins the format of persisted HandoffState. Bumping
/// `formatVersion` causes restore attempts of older payloads to fail
/// gracefully (returns nil → state machine uses supplied initialState).
private struct PersistedHandoffState: Codable {
    let formatVersion: Int
    let state: HandoffState
    let savedAt: Date
}

public enum HandoffStatePersistence {

    /// Current persistence format version. Bump when HandoffState's
    /// serialization shape changes incompatibly.
    public static let currentFormatVersion: Int = 1

    private static let key = "com.LoopKit.OmniBLE.persistedHandoffState"
    private static let log = OSLog(category: "HandoffStatePersistence")

    /// Persist the given state to App Group UserDefaults. Logs + drops
    /// silently on encode failure (the state machine continues working in
    /// memory; only crash recovery is degraded).
    public static func save(_ state: HandoffState, to defaults: UserDefaults) {
        let persisted = PersistedHandoffState(
            formatVersion: currentFormatVersion,
            state: state,
            savedAt: Date()
        )
        do {
            let data = try JSONEncoder().encode(persisted)
            defaults.set(data, forKey: key)
        } catch {
            log.error("save failed: %{public}@", String(describing: error))
        }
    }

    /// Restore a previously persisted state. Returns nil if:
    /// - no persisted state exists
    /// - the persisted state's formatVersion doesn't match currentFormatVersion
    /// - decode fails for any reason
    /// On nil return, the state machine should use its supplied initialState.
    public static func load(from defaults: UserDefaults) -> HandoffState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            let persisted = try JSONDecoder().decode(PersistedHandoffState.self, from: data)
            guard persisted.formatVersion == currentFormatVersion else {
                log.default("load: ignoring persisted state with format version %d (current %d)",
                            persisted.formatVersion, currentFormatVersion)
                return nil
            }
            log.default("load: restored state from %{public}@",
                        ISO8601DateFormatter().string(from: persisted.savedAt))
            return persisted.state
        } catch {
            log.error("load failed: %{public}@", String(describing: error))
            return nil
        }
    }

    /// Test helper: clear the persisted state.
    public static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
    }
}
