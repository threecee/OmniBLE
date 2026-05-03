//
//  HandoffSettings.swift
//  OmniBLE
//
//  Persisted user preference for handoff behavior. Stored in the shared
//  App Group UserDefaults so both Loop iOS (writer) and LoopWatchApp
//  (reader/writer) see the same value.
//

import Foundation

public struct HandoffSettings: Codable, Equatable {
    public var mode: HandoffMode

    /// Default mode is `.manual` until B.2.e ships actual BLE take-over.
    /// After B.2.e, the default flips to `.automatic` per the user's
    /// preference recorded in the B.2.d spec §1.
    public static let defaultMode: HandoffMode = .automatic

    public init(mode: HandoffMode = HandoffSettings.defaultMode) {
        self.mode = mode
    }

    public static let userDefaultsKey = "loop-and-learn.handoffSettings"
    public static let appGroupIdentifier = "group.com.threecee.loop.LoopGroup"

    /// Convenience accessor: the App Group UserDefaults instance that all
    /// handoff state, settings, and snapshot caches share. Falls back to
    /// `.standard` if the App Group cannot be resolved (test/sim path).
    /// Replaces inlined `UserDefaults(suiteName: HandoffSettings.appGroupIdentifier) ?? .standard`
    /// callsites across OmniBLE/Common and Loop's WatchHandoff modules.
    public static var appGroupDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    /// B.8.4: convenience accessor for the App Group container URL, used for
    /// shared file storage (e.g., the `<AppGroup>/snapshot.json` fallback when
    /// the algorithm-state snapshot payload exceeds the applicationContext
    /// budget). Falls back to the temporary directory if the App Group cannot
    /// be resolved (test/sim path) so callers don't have to handle nil.
    public static var appGroupContainerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? FileManager.default.temporaryDirectory
    }

    public static func load(from defaults: UserDefaults) -> HandoffSettings {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(HandoffSettings.self, from: data)
        else {
            return HandoffSettings()
        }
        return decoded
    }

    public func save(to defaults: UserDefaults) throws {
        let data = try JSONEncoder().encode(self)
        defaults.set(data, forKey: HandoffSettings.userDefaultsKey)
    }
}
