//
//  AlgorithmStateSnapshot.swift
//  OmniBLE
//
//  Phone → Watch payload sent at the end of every successful Loop iteration.
//  The watch caches the latest snapshot and consults it at takeover to decide
//  whether to skip warmup (run dosing immediately) or fall back to today's
//  full-warmup behavior. See docs/superpowers/specs/2026-05-03-b8-...md for
//  the validation rules and failure-mode matrix.
//

import Foundation
import LoopKit

/// Schema version is carried by the wrapping `PhoneWatchMessage` envelope
/// (see B.8 T3); do NOT add a `schemaVersion` field here.
public struct AlgorithmStateSnapshot: Codable, Equatable, Sendable {
    public let snapshotID: UUID
    public let createdAt: Date
    public let phoneIterationDate: Date
    public let glucoseSamples: [StoredGlucoseSample]
    public let doseHistory: [DoseEntry]
    public let carbEntries: [StoredCarbEntry]
    public let pumpStatus: PumpStatusSnapshot
    public let activeOverride: TemporaryScheduleOverride?

    public init(snapshotID: UUID,
                createdAt: Date,
                phoneIterationDate: Date,
                glucoseSamples: [StoredGlucoseSample],
                doseHistory: [DoseEntry],
                carbEntries: [StoredCarbEntry],
                pumpStatus: PumpStatusSnapshot,
                activeOverride: TemporaryScheduleOverride?) {
        self.snapshotID = snapshotID
        self.createdAt = createdAt
        self.phoneIterationDate = phoneIterationDate
        self.glucoseSamples = glucoseSamples
        self.doseHistory = doseHistory
        self.carbEntries = carbEntries
        self.pumpStatus = pumpStatus
        self.activeOverride = activeOverride
    }
}

// MARK: - Freshness check (B.8.4)

extension AlgorithmStateSnapshot {
    /// Maximum age (relative to `phoneIterationDate`) at which a snapshot is
    /// still trusted to skip warmup on the watch. Beyond this window the
    /// watch falls back to a full warmup rather than dose against potentially
    /// stale state. Pediatric T1D safety: prefer warmup over stale data.
    public static let maxAgeForSkipWarmup: TimeInterval = 7 * 60

    /// Returns `true` when this snapshot's `phoneIterationDate` is within
    /// `maxAgeForSkipWarmup` seconds of `now`. Used by the watch's
    /// `WatchAlgorithmDriver` to gate the `.skipWarmup` hydration path.
    public func isFreshEnoughForSkipWarmup(now: Date = Date()) -> Bool {
        return now.timeIntervalSince(phoneIterationDate) < Self.maxAgeForSkipWarmup
    }
}
