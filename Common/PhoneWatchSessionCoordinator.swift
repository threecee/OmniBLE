//
//  PhoneWatchSessionCoordinator.swift
//  OmniBLE
//
//  Owns the PhoneWatchTransport; exposes connection state via @Published
//  properties; dispatches incoming messages to type-specific handlers.
//
//  B.10: lifted from Loop/WatchApp Extension paired files into OmniBLE.
//  Behavior is role-conditional, not platform-conditional:
//
//    - heartbeat senderRole derives from `role: HandoffRole`.
//    - claimedOwner / split-brain access to the orchestrator is performed
//      via a small `OrchestratorAccessor` protocol the call site supplies.
//      This breaks the OmniBLE -> HandoffOrchestrator (still in Loop, until
//      Pair E lifts) cyclic dependency.
//    - split-brain detection diverges in semantics:
//        * phone: log advisory only (phone-wins arbitration; the watch
//                 self-demotes on its receipt of our heartbeat).
//        * watch: log + immediate `commandsAllowed = false` + emit
//                 `userRequestHandoff(to: .phone)` so the state machine
//                 reverts.
//    - inbound `.settingsSync` and `.algorithmStateSnapshot` messages are
//      phone -> watch only; on the watch the coordinator updates
//      `WatchSettingsCache.shared` / `WatchAlgorithmSnapshotCache.shared`
//      via injected closures (kept watch-app-local to avoid dragging
//      watchOS singletons into OmniBLE). The phone passes nil for both;
//      the corresponding inbound branches no-op there.
//

import Foundation
import Combine
import os.log

// MARK: - Orchestrator accessor protocol

/// Minimal surface the coordinator needs to read/write on the orchestrator
/// for heartbeat claimedOwner population and split-brain demotion. Supplied
/// by the call site so this file does not depend on `HandoffOrchestrator`
/// directly. Once Pair E lifts the orchestrator into OmniBLE this
/// indirection can be revisited.
@MainActor
public protocol PhoneWatchOrchestratorAccessor: AnyObject {
    /// Current handoff state (used to populate heartbeat.claimedOwner).
    var currentHandoffState: HandoffState { get }
    /// Set when watch-side split-brain demotion fires.
    func splitBrainDemoteSelf()
}

@MainActor
public final class PhoneWatchSessionCoordinator: ObservableObject {
    /// Shared accessor populated by LoopAppManager / ExtensionDelegate at
    /// launch. SwiftUI views that don't have direct access to LoopAppManager
    /// (e.g., SettingsView, which receives its view model from above) read
    /// this accessor to observe state. Optional; may be nil during initial
    /// app boot or in test contexts.
    public static weak var shared: PhoneWatchSessionCoordinator?

    @Published public private(set) var lastHeartbeatReceivedAt: Date?
    @Published public private(set) var lastHeartbeatSentAt: Date?
    @Published public private(set) var isCounterpartReachable: Bool = false

    private let role: HandoffRole
    private var transport: PhoneWatchTransport
    private let appBuildNumber: String
    private let clock: () -> Date
    private var heartbeat: HeartbeatScheduler?

    /// Accessor supplied by the call site (LoopAppManager / ExtensionDelegate)
    /// after the orchestrator is constructed. Optional; may be nil during
    /// boot before the orchestrator publishes its `shared` accessor or in
    /// test contexts.
    public weak var orchestratorAccessor: PhoneWatchOrchestratorAccessor?

    /// Watch-only sink for inbound settings-sync messages. Phone passes nil.
    /// In production wired to `WatchSettingsCache.shared.update(_:)`.
    private let onSettingsSyncReceived: ((PhoneWatchSettingsSync) -> Void)?

    /// Watch-only sink for inbound algorithm-state snapshots. Phone passes nil.
    /// In production wired to `WatchAlgorithmSnapshotCache.shared.update(_:)`.
    private let onSnapshotReceived: ((AlgorithmStateSnapshot) -> Void)?

    /// log channel for split-brain detection.
    private let log = OSLog(category: "PhoneWatchSessionCoordinator")

    /// orchestrator subscribes to incoming non-heartbeat messages
    /// (modeSwitch / pairingHandoff). The coordinator continues to handle
    /// heartbeat internally; modeSwitch / pairingHandoff are forwarded.
    public var onHandoffMessage: ((PhoneWatchMessage) -> Void)?

    /// convenience reachability surface for HandoffPolicyEngine.
    /// `isCounterpartReachable` already tracks transport.isReachable updated
    /// on each sent heartbeat; surface as `isReachable` for orchestrator
    /// observation. When no heartbeat has been sent yet, defaults to false.
    public var isReachable: Bool {
        return isCounterpartReachable
    }

    /// "Connected" = we received a heartbeat within the last 90 seconds.
    public var isConnected: Bool {
        guard let when = lastHeartbeatReceivedAt else { return false }
        return clock().timeIntervalSince(when) < 90
    }

    public init(role: HandoffRole,
                transport: PhoneWatchTransport,
                appBuildNumber: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                clock: @escaping () -> Date = Date.init,
                onSettingsSyncReceived: ((PhoneWatchSettingsSync) -> Void)? = nil,
                onSnapshotReceived: ((AlgorithmStateSnapshot) -> Void)? = nil) {
        self.role = role
        self.transport = transport
        self.appBuildNumber = appBuildNumber
        self.clock = clock
        self.onSettingsSyncReceived = onSettingsSyncReceived
        self.onSnapshotReceived = onSnapshotReceived
    }

    public func start() {
        transport.onIncomingMessage = { [weak self] message in
            Task { @MainActor in self?.handle(incoming: message) }
        }
        heartbeat = HeartbeatScheduler(interval: 30) { [weak self] in
            Task { @MainActor in self?.sendHeartbeat() }
        }
        heartbeat?.start()
    }

    public func stop() {
        heartbeat?.stop()
        heartbeat = nil
    }

    // MARK: - Send

    /// queue a mode-switch message (transferUserInfo, fire-and-forget).
    public func sendModeSwitch(_ ms: PhoneWatchModeSwitch) {
        transport.queueMessage(.modeSwitch(ms))
    }

    /// queue a pairing-handoff message (transferUserInfo).
    public func sendPairingHandoff(_ ph: PhoneWatchPairingHandoff) {
        transport.queueMessage(.pairingHandoff(ph))
    }

    /// queue a settings-sync message (transferUserInfo). Phone -> watch only;
    /// calling on the watch side is a no-op-but-not-harmful (the watch's
    /// HandoffOrchestrator never invokes this). Kept callable on both sides
    /// for API symmetry.
    public func sendSettingsSync(_ sync: PhoneWatchSettingsSync) {
        transport.queueMessage(.settingsSync(sync))
    }

    public func sendHeartbeat() {
        let hb = PhoneWatchHeartbeat(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: clock(),
            senderRole: role == .phone ? .phone : .watch,
            appBuildNumber: appBuildNumber,
            claimedOwner: orchestratorAccessor?.currentHandoffState.currentOwner
        )
        transport.sendMessage(.heartbeat(hb), reply: nil, onError: { _ in })
        lastHeartbeatSentAt = clock()
        isCounterpartReachable = transport.isReachable
    }

    /// For debug-echo (long-press on Settings row, phone-only UI). Sends a
    /// heartbeat with an expected reply; on success, returns the round-trip
    /// time via the closure. Kept callable on both sides; the watch has no
    /// UI that calls it.
    public func sendDebugEcho(_ completion: @escaping (Result<TimeInterval, Error>) -> Void) {
        let now = clock()
        let hb = PhoneWatchHeartbeat(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: now,
            senderRole: role == .phone ? .phone : .watch,
            appBuildNumber: appBuildNumber,
            claimedOwner: orchestratorAccessor?.currentHandoffState.currentOwner
        )
        transport.sendMessage(.heartbeat(hb), reply: { result in
            switch result {
            case .success:
                DispatchQueue.main.async {
                    completion(.success(self.clock().timeIntervalSince(now)))
                }
            case .failure(let err):
                DispatchQueue.main.async { completion(.failure(err)) }
            }
        }, onError: { err in
            DispatchQueue.main.async { completion(.failure(err)) }
        })
    }

    // MARK: - Receive

    private func handle(incoming message: PhoneWatchMessage) {
        switch message {
        case .heartbeat(let hb):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: hb.protocolVersion) else { return }
            lastHeartbeatReceivedAt = clock()
            isCounterpartReachable = true

            // Split-brain detection. Both halves are load-bearing pediatric
            // safety code: phone-wins arbitration means the watch self-demotes
            // and the phone retains ownership.
            if let orch = orchestratorAccessor {
                let myOwner: HandoffOwner = role == .phone ? .phone : .watch
                let claimedOther: HandoffOwner = role == .phone ? .watch : .phone
                if orch.currentHandoffState.currentOwner == myOwner,
                   hb.claimedOwner == claimedOther {
                    switch role {
                    case .phone:
                        log.error("split-brain detected (advisory): watch heartbeat claims watch is owner; phone retains ownership per arbitration rule")
                    case .watch:
                        log.error("split-brain detected: I (watch) believe I'm owner, but phone heartbeat claims phone is owner; phone wins, demoting self")
                        orch.splitBrainDemoteSelf()
                    }
                }
            }
        case .modeSwitch(let ms):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: ms.protocolVersion) else { return }
            log.default("received mode switch %{public}@ (transition %{public}@)",
                        String(describing: ms.targetMode.rawValue),
                        ms.transitionId.uuidString)
            // forward to orchestrator (if subscribed).
            onHandoffMessage?(message)
        case .pairingHandoff(let ph):
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: ph.protocolVersion) else { return }
            log.default("received pairing handoff for pod %{public}@ (%d bytes)",
                        ph.podId,
                        ph.pairingPayload.count)
            // forward to orchestrator (if subscribed).
            onHandoffMessage?(message)
        case .settingsSync(let sync):
            // Phone -> watch only. The phone never receives one (no-op there).
            guard let onSettingsSyncReceived = onSettingsSyncReceived else { return }
            guard PhoneWatchProtocol.shouldAccept(incomingVersion: sync.protocolVersion) else { return }
            log.default("received settings sync (protocolVersion=%d)", sync.protocolVersion)
            onSettingsSyncReceived(sync)
        case .algorithmStateSnapshot(let snap):
            // Phone -> watch only. The phone never receives one (no-op there).
            // No per-payload protocolVersion check: AlgorithmStateSnapshot has no
            // version field of its own. Schema compatibility is enforced at envelope
            // (PhoneWatchMessage) decode time — older receivers throw on the unknown
            // .algorithmStateSnapshot Kind raw value before the payload is parsed.
            guard let onSnapshotReceived = onSnapshotReceived else { return }
            log.default("received algorithm-state snapshot %{public}@ (createdAt=%{public}@)",
                        snap.snapshotID.uuidString,
                        String(describing: snap.createdAt))
            onSnapshotReceived(snap)
        case .algorithmStateSnapshotPointer:
            // ExtensionDelegate.handlePhoneWatchMessageData converts pointer
            // messages into inline `.algorithmStateSnapshot` messages (after
            // reading the file from the App Group container) before forwarding
            // them to the transport. So this branch is unreachable in
            // production — kept as a defensive no-op so the switch stays
            // exhaustive. If this ever fires on the watch, log it loudly: it
            // means the pointer slipped past the rewrap shim. Phone never
            // receives pointer messages either (snapshots are phone -> watch).
            if role == .watch {
                log.error("unexpected algorithmStateSnapshotPointer at coordinator — pointer should have been re-wrapped at ExtensionDelegate")
            }
        }
    }
}
