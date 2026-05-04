//
//  ShadowStateScheduler.swift
//  OmniBLE
//
//  Periodic + change-driven trigger for shadow-state proactive shipping.
//  Fires `fire` closure every `interval` seconds while running, plus
//  immediately on `notifyPodStateChanged()`. The orchestrator's fire closure
//  emits HandoffEvent.shadowStateRefreshDue into the state machine.
//
//  B.10: lifted from Loop/WatchApp Extension paired files into OmniBLE so
//  both phone and watch consume a single source of truth. Behavior is
//  identical on both roles; the `role` parameter is accepted for future
//  role-conditional extensions and to make the bootstrap call site
//  symmetric with the rest of the handoff stack.
//

import Foundation

@MainActor
public final class ShadowStateScheduler {

    public static let defaultInterval: TimeInterval = 5 * 60   // 5 min

    private let role: HandoffRole
    private let interval: TimeInterval
    private let clock: () -> Date
    private var fire: () -> Void

    private var task: Task<Void, Never>?

    public init(role: HandoffRole,
                interval: TimeInterval = ShadowStateScheduler.defaultInterval,
                clock: @escaping () -> Date = Date.init,
                fire: @escaping () -> Void) {
        self.role = role
        self.interval = interval
        self.clock = clock
        self.fire = fire
    }

    public func setFire(_ newFire: @escaping () -> Void) {
        fire = newFire
    }

    public func start() {
        stop()
        task = Task { [weak self, interval] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run { self.fire() }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func notifyPodStateChanged() {
        fire()
    }
}
