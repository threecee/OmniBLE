//
//  HeartbeatScheduler.swift
//  OmniBLE
//
//  Fires a closure every `interval` seconds while running. Task-based
//  (cleaner than Timer at this scale, better cancellation story).
//
//  B.10: lifted from Loop/WatchApp Extension paired files (no semantic
//  divergence). Used internally by `PhoneWatchSessionCoordinator` to
//  schedule the 30s heartbeat cadence.
//

import Foundation

public final class HeartbeatScheduler {
    private let interval: TimeInterval
    private let fire: () -> Void
    private var task: Task<Void, Never>?

    public init(interval: TimeInterval, fire: @escaping () -> Void) {
        self.interval = interval
        self.fire = fire
    }

    public func start() {
        stop()
        task = Task { [interval, fire] in
            while !Task.isCancelled {
                fire()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
