//
//  HandoffStack.swift
//  OmniBLE
//
//  Single-call assembly of the 6-component phone↔watch handoff stack.
//  Replaces ~54 LOC of hand-built bootstrap chains previously duplicated
//  across `LoopAppManager` (iOS) and `ExtensionDelegate` (watch). Each
//  caller now invokes `HandoffStack.assemble(role:)` once and retains
//  the components it needs (orchestrator, coordinator, transport, ...).
//
//  Scope:
//  - Constructs WCSessionPhoneWatchTransport, PhoneWatchSessionCoordinator,
//    HandoffStateMachine, HandoffPolicyEngine, ShadowStateScheduler,
//    HandoffOrchestrator in dependency order, wired together.
//  - Does NOT call `coordinator.start()` or `orchestrator.start()` — the
//    caller is responsible for starting the stack after attaching any
//    additional wiring (e.g., `phoneWatchCoordinator.orchestratorAccessor`
//    is set by the caller before `start()` because the accessor is
//    typically the orchestrator itself).
//  - Does NOT publish `HandoffOrchestrator.shared` /
//    `PhoneWatchSessionCoordinator.shared` — caller does that, since the
//    callers retain references for their own use.
//  - Does NOT install host-specific peripherals (HealthKit, G7,
//    ExtendedRuntimeCoordinator on watch; AlgorithmStateSnapshotEmitter
//    on phone). Those stay in the host bootstrap.
//
//  Role-conditional parameters (all optional, defaulted to `nil`):
//  - `pumpManager` — phone supplies the eagerly-constructed
//    `OmniBLEPumpManager` (passed as `OmniBLEPodOwner?`); watch passes nil
//    and relies on lazy construction via `makeWatchSidePumpManager`.
//  - `settingsSyncProvider` — phone supplies a closure returning the
//    current `PhoneWatchSettingsSync`; watch passes nil (settings sync
//    is phone→watch only).
//  - `onSettingsSyncReceived` / `onSnapshotReceived` — watch supplies
//    closures that update its `WatchSettingsCache` /
//    `WatchAlgorithmSnapshotCache`; phone passes nil (phone never
//    receives these messages).
//  - `makeWatchSidePumpManager` — watch supplies the lazy factory used
//    on first `.watchDriver` transition; phone passes nil.
//
//  Phone-only callers should pass non-nil for `pumpManager` and
//  `settingsSyncProvider`. Watch-only callers should pass non-nil for
//  the three closure parameters. Cross-injection is harmless (the
//  unused parameters never fire on the wrong role) but is not a tested
//  configuration.
//

import Foundation

@MainActor
public final class HandoffStack {
    public let transport: WCSessionPhoneWatchTransport
    public let coordinator: PhoneWatchSessionCoordinator
    public let stateMachine: HandoffStateMachine
    public let policyEngine: HandoffPolicyEngine
    public let shadowScheduler: ShadowStateScheduler
    public let orchestrator: HandoffOrchestrator

    private init(transport: WCSessionPhoneWatchTransport,
                 coordinator: PhoneWatchSessionCoordinator,
                 stateMachine: HandoffStateMachine,
                 policyEngine: HandoffPolicyEngine,
                 shadowScheduler: ShadowStateScheduler,
                 orchestrator: HandoffOrchestrator) {
        self.transport = transport
        self.coordinator = coordinator
        self.stateMachine = stateMachine
        self.policyEngine = policyEngine
        self.shadowScheduler = shadowScheduler
        self.orchestrator = orchestrator
    }

    /// Assemble the handoff stack in dependency order. See file header
    /// for the role-conditional parameter contract.
    public static func assemble(
        role: HandoffRole,
        appGroupDefaults: UserDefaults = HandoffSettings.appGroupDefaults,
        pumpManager: OmniBLEPodOwner? = nil,
        settingsSyncProvider: (() -> PhoneWatchSettingsSync?)? = nil,
        onSettingsSyncReceived: ((PhoneWatchSettingsSync) -> Void)? = nil,
        onSnapshotReceived: ((AlgorithmStateSnapshot) -> Void)? = nil,
        onAPNsTokenPublishReceived: ((APNsTokenPublication) -> Void)? = nil,
        makeWatchSidePumpManager: (() -> OmniBLEPumpManager)? = nil,
        nightscoutAPISecretProvider: @escaping () -> String = { "" },
        clock: @escaping () -> Date = { Date() }
    ) -> HandoffStack {
        // 1. Transport — leaf; depends only on WCSession.
        let transport = WCSessionPhoneWatchTransport(role: role)

        // 2. Coordinator — depends on transport and watch-only cache hooks.
        let coordinator = PhoneWatchSessionCoordinator(
            role: role,
            transport: transport,
            onSettingsSyncReceived: onSettingsSyncReceived,
            onSnapshotReceived: onSnapshotReceived,
            onAPNsTokenPublishReceived: onAPNsTokenPublishReceived
        )

        // 3. State machine — depends only on UserDefaults for persistence.
        let stateMachine = HandoffStateMachine(
            initialState: .phoneDriver,
            role: role,
            appGroupDefaults: appGroupDefaults
        )

        // 4. Policy engine — depends on coordinator (observable) + settings.
        //    `emit` is wired by the orchestrator's `start()` (we leave a
        //    placeholder here to mirror the previous bootstrap chain).
        let settings = HandoffSettings.load(from: appGroupDefaults)
        let policyEngine = HandoffPolicyEngine(
            role: role,
            coordinator: coordinator,
            settings: settings,
            emit: { _ in /* wired via orchestrator.start() */ }
        )

        // 5. Shadow scheduler — leaf; orchestrator re-wires `fire` via
        //    `setFire(_:)` in `start()`.
        let shadowScheduler = ShadowStateScheduler(role: role,
                                                   fire: { /* wired via orchestrator.start() */ })

        // 6. Orchestrator — depends on all of the above plus role-conditional
        //    closures.
        let orchestrator = HandoffOrchestrator(
            role: role,
            coordinator: coordinator,
            stateMachine: stateMachine,
            policyEngine: policyEngine,
            shadowScheduler: shadowScheduler,
            userDefaults: appGroupDefaults,
            pumpManager: pumpManager,
            settingsSyncProvider: settingsSyncProvider,
            makeWatchSidePumpManager: makeWatchSidePumpManager,
            nightscoutAPISecretProvider: nightscoutAPISecretProvider,
            clock: clock
        )

        return HandoffStack(
            transport: transport,
            coordinator: coordinator,
            stateMachine: stateMachine,
            policyEngine: policyEngine,
            shadowScheduler: shadowScheduler,
            orchestrator: orchestrator
        )
    }
}
