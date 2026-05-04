//
//  HandoffPolicyEngine.swift
//  OmniBLE
//
//  Observes connection signals from PhoneWatchSessionCoordinator, applies
//  conservative thresholds (60s heartbeat absence, 30s user-activity quiet,
//  10min cached-pod-state freshness), and emits
//  HandoffEvent.policyRequestedHandoff into the state machine via the
//  closure passed at init.
//
//  B.10: lifted from Loop/WatchApp Extension paired files. Phase 1
//  discovery showed 41 diff lines, all comments — no semantic divergence.
//  Lifted as a single public final class with `role: HandoffRole` for
//  bootstrap symmetry; behavior is identical on phone and watch.
//

import Foundation
import Combine

@MainActor
public protocol HandoffPolicyCoordinatorObservable: AnyObject {
    var isReachable: Bool { get }
    var lastHeartbeatReceivedAt: Date? { get }
}

extension PhoneWatchSessionCoordinator: HandoffPolicyCoordinatorObservable {}

@MainActor
public final class HandoffPolicyEngine {

    public static let absenceThreshold: TimeInterval = 60       // seconds
    public static let userActivityQuietThreshold: TimeInterval = 30
    public static let cachedPodStateMaxAge: TimeInterval = 10 * 60
    public static let rebounceWindow: TimeInterval = 5

    private let role: HandoffRole
    private let coordinator: any HandoffPolicyCoordinatorObservable
    private var settings: HandoffSettings
    private let clock: () -> Date
    private let emit: (HandoffEvent) -> Void

    private var ticker: Task<Void, Never>?
    private var lastEmittedAt: Date?

    // State that production code populates from external observers; tests poke directly.
    private var currentOwner: HandoffOwner = .phone
    private var phoneStableReachableSince: Date?
    private var lastUserInteractionAt: Date?
    private var cachedPodStateAt: Date?

    public init(role: HandoffRole,
                coordinator: any HandoffPolicyCoordinatorObservable,
                settings: HandoffSettings,
                clock: @escaping () -> Date = Date.init,
                emit: @escaping (HandoffEvent) -> Void) {
        self.role = role
        self.coordinator = coordinator
        self.settings = settings
        self.clock = clock
        self.emit = emit
    }

    public func start() {
        stop()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.evaluateNow() }
                // efficiency: drop tick from 1Hz to 5s. The coarsest threshold the
                // engine checks (60s heartbeat absence) is 12x the new tick — still
                // well within responsiveness budget. 60x over-sampling on watchOS
                // was a battery drain.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// Public for orchestrator to push fresh settings without re-instantiating.
    public func updateSettings(_ new: HandoffSettings) {
        settings = new
    }

    /// Evaluation of all preconditions; emits policyRequestedHandoff if applicable.
    /// Public for unit tests.
    public func evaluateNow() {
        let now = clock()

        // Rebounce
        if let last = lastEmittedAt, now.timeIntervalSince(last) < Self.rebounceWindow {
            return
        }

        // User activity gate
        if let activity = lastUserInteractionAt,
           now.timeIntervalSince(activity) < Self.userActivityQuietThreshold {
            return
        }

        // Cached pod state freshness gate (only for takeover; revert doesn't need it)
        let cachedFreshEnough = cachedPodStateAt
            .map { now.timeIntervalSince($0) <= Self.cachedPodStateMaxAge } ?? true

        switch (currentOwner, settings.mode) {

        case (.phone, .automatic):
            // The non-driving side detects the driver disappearing and
            // requests a takeover. On the watch this is the common path
            // (phone ownership is the default); on iOS it is rarer but
            // supported for symmetry. Check heartbeat absence threshold +
            // cached state freshness.
            if absenceTriggered(now: now), cachedFreshEnough {
                emit(.policyRequestedHandoff(target: .watch))
                lastEmittedAt = now
            }

        case (.watch, .automatic), (.watch, .manualWithAutoRevert):
            // Watch is currently driver; phone returns reachable + stable
            // for >= absenceThreshold seconds — emit revert to phone.
            if let stableSince = phoneStableReachableSince,
               now.timeIntervalSince(stableSince) >= Self.absenceThreshold,
               coordinator.isReachable {
                emit(.policyRequestedHandoff(target: .phone))
                lastEmittedAt = now
            }

        default:
            // .manual mode never emits, .manualWithAutoRevert + phoneOwner doesn't auto-takeover
            return
        }
    }

    private func absenceTriggered(now: Date) -> Bool {
        guard let last = coordinator.lastHeartbeatReceivedAt else {
            // No heartbeat ever received -> cannot trigger automatic takeover safely
            return false
        }
        return now.timeIntervalSince(last) >= Self.absenceThreshold
    }

    // MARK: - Public hooks for orchestrator / tests

    public func markCurrentOwner(_ owner: HandoffOwner) {
        currentOwner = owner
    }

    public func markPhoneStableSince(_ when: Date?) {
        phoneStableReachableSince = when
    }

    public func markUserInteractedAt(_ when: Date) {
        lastUserInteractionAt = when
    }

    public func markCachedPodStateAge(_ when: Date) {
        cachedPodStateAt = when
    }

    // MARK: - B.4 Issue #2: test inspectors (public so unit tests can read).
    public var currentOwnerForTesting: HandoffOwner { currentOwner }
    public var phoneStableReachableSinceForTesting: Date? { phoneStableReachableSince }
    public var lastUserInteractionAtForTesting: Date? { lastUserInteractionAt }
    public var cachedPodStateAtForTesting: Date? { cachedPodStateAt }
}
