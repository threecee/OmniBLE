//
//  APNsTokenStore.swift
//  OmniBLE
//
//  App-Group-backed persistence for the local + counterpart APNs device
//  tokens published in B.11.0. Uses the `UserDefaults+Codable` helpers
//  established in B.8.1 (silent-encode-failure is the established
//  contract for App Group cache writes; the Codable type is small).
//
//  Two slots keyed by role:
//    - `.phone` slot — written by the iOS app on its own
//      `didRegisterForRemoteNotifications` callback, written by the watch
//      on `apnsTokenPublish` receipt with role .phone.
//    - `.watch` slot — written by the watch on its own
//      `didRegisterForRemoteNotifications` callback, written by the iOS
//      app on `apnsTokenPublish` receipt with role .watch.
//
//  No driver-gate enforcement here — both slots are writable from either
//  side. Driver-only-writes is enforced one layer up by the
//  RemoteCareUploader (B.11.1) and the devicestatus rendezvous (B.11.2).
//

import Foundation

public struct APNsTokenStore {
    private let defaults: UserDefaults

    public static let phoneTokenKey = "loop-and-learn.apnsToken.phone"
    public static let watchTokenKey = "loop-and-learn.apnsToken.watch"

    public init(defaults: UserDefaults = HandoffSettings.appGroupDefaults) {
        self.defaults = defaults
    }

    /// Persist a publication record under the slot indicated by its `role`.
    /// Idempotent: re-publishing the same token overwrites in place.
    public func save(_ publication: APNsTokenPublication) {
        let key = Self.key(for: publication.role)
        defaults.set(codable: publication, forKey: key)
    }

    /// Read the persisted publication for the given role. Nil if no token
    /// has been published yet, or if decode fails (matches the silent-fail
    /// contract from `UserDefaults+Codable`).
    public func load(role: HandoffRole) -> APNsTokenPublication? {
        defaults.codableValue(forKey: Self.key(for: role), as: APNsTokenPublication.self)
    }

    /// Clear a slot (test harness convenience; not used in production).
    public func clear(role: HandoffRole) {
        defaults.removeObject(forKey: Self.key(for: role))
    }

    private static func key(for role: HandoffRole) -> String {
        switch role {
        case .phone: return phoneTokenKey
        case .watch: return watchTokenKey
        }
    }
}
