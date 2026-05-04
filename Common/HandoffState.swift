//
//  HandoffState.swift
//  OmniBLE
//
//  States the bonding-handoff state machine can be in, plus supporting
//  small types (direction, recovery reason, transition record).
//

import Foundation

public enum HandoffDirection: String, Codable, Equatable {
    case phoneToWatch
    case watchToPhone

    public var origin: HandoffOwner {
        switch self {
        case .phoneToWatch: return .phone
        case .watchToPhone: return .watch
        }
    }

    public var destination: HandoffOwner {
        switch self {
        case .phoneToWatch: return .watch
        case .watchToPhone: return .phone
        }
    }
}

public enum HandoffRecoveryReason: String, Codable, Equatable {
    case timeoutWaitingForConfirmation
    case rejectedByCounterpart
    case localFailureDuringTransition
    case restoredExpiredPending
    /// B.11.3: pre-flip rendezvous upload failed. NOTE: under Option D
    /// (Carl-decided), this recovery reason is NOT currently emitted —
    /// the pre-flip rendezvous publish is fire-and-forget and never
    /// surfaces a failure. The case is retained additively for future
    /// surface area (and to keep the structural mechanical landing per
    /// plan); see `HandoffOrchestrator` for the rationale.
    case rendezvousPublishFailed
}

public enum HandoffState: Equatable, Codable {
    case phoneDriver
    /// B.11.3: 4th tuple element `tokenRendezvousPublished` tracks whether
    /// the outgoing-driver pre-flip rendezvous publication has fired for
    /// this transition. Set true by `.rendezvousPublishCompleted`. The
    /// flag is advisory — pre-flip publish is fire-and-forget; idempotency
    /// on the new driver's first post-flip upload is the load-bearing
    /// safety property.
    case handoffPending(direction: HandoffDirection,
                        transitionId: UUID,
                        deadline: Date,
                        tokenRendezvousPublished: Bool)
    case watchDriver
    case recovering(reason: HandoffRecoveryReason, lastKnownOwner: HandoffOwner)

    /// Stable steady-state owner, or nil if not in a stable state.
    public var stableOwner: HandoffOwner? {
        switch self {
        case .phoneDriver: return .phone
        case .watchDriver: return .watch
        case .handoffPending, .recovering: return nil
        }
    }

    public var isTransitioning: Bool {
        if case .handoffPending = self { return true }
        return false
    }
}

/// Distilled snapshot of HandoffState for logging without UUID/Date noise.
public enum HandoffStateSnapshot: String, Codable, Equatable {
    case phoneDriver
    case handoffPendingPhoneToWatch
    case handoffPendingWatchToPhone
    case watchDriver
    case recovering
}

public extension HandoffState {
    var snapshot: HandoffStateSnapshot {
        switch self {
        case .phoneDriver: return .phoneDriver
        case .handoffPending(direction: .phoneToWatch, _, _, _): return .handoffPendingPhoneToWatch
        case .handoffPending(direction: .watchToPhone, _, _, _): return .handoffPendingWatchToPhone
        case .watchDriver: return .watchDriver
        case .recovering: return .recovering
        }
    }

    /// derive the current owner from a HandoffState for use by
    /// the policy engine's `markCurrentOwner` hook. Pending transitions are
    /// still owned by the origin until commit; ambiguous states return nil.
    public var currentOwner: HandoffOwner? {
        switch self {
        case .phoneDriver: return .phone
        case .watchDriver: return .watch
        case .handoffPending(direction: let dir, _, _, _):
            // Pending TO watch means phone is still owner until commit;
            // pending TO phone means watch is still owner until commit.
            return dir.origin
        case .recovering: return nil  // ambiguous; don't update
        }
    }
}

public enum HandoffTransitionTrigger: String, Codable, Equatable {
    case userManual
    case policyAutomatic
    case messageFromCounterpart
    case timeout
    case shadowRefresh
    /// B.11.3: trigger for `.rendezvousPublishCompleted` /
    /// `.rendezvousPublishFailed` events.
    case rendezvousOutcome
}

public struct HandoffTransitionRecord: Equatable, Codable {
    public let timestamp: Date
    public let from: HandoffStateSnapshot
    public let to: HandoffStateSnapshot
    public let trigger: HandoffTransitionTrigger

    public init(timestamp: Date, from: HandoffStateSnapshot,
                to: HandoffStateSnapshot, trigger: HandoffTransitionTrigger) {
        self.timestamp = timestamp
        self.from = from
        self.to = to
        self.trigger = trigger
    }
}

public enum HandoffRole: String, Codable, Equatable {
    case phone
    case watch

    public var asOwner: HandoffOwner {
        switch self {
        case .phone: return .phone
        case .watch: return .watch
        }
    }
}
