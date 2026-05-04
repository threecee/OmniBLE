//
//  HandoffOrchestrator.swift
//  OmniBLE
//
//  Glue between PhoneWatchSessionCoordinator and the
//  HandoffStateMachine + HandoffPolicyEngine + ShadowStateScheduler stack.
//  Executes HandoffSideEffect values returned by the state machine.
//
//  B.10: lifted from Loop/WatchApp Extension paired files. Behavior is
//  role-conditional, not platform-conditional. Five (d) divergences from
//  Phase 1 discovery, all resolved as role-gates:
//
//    1. Settings-sync emission (phone-only). The optional
//       `settingsSyncProvider` is nil on the watch — `emitSettingsSync()`
//       guards on it and no-ops there. The phone-only `lastEmittedSync`
//       dedup field lives on the lifted class but is only mutated in the
//       phone path.
//    2. NSSystemTimeZoneDidChange observer (phone-only). Installed in
//       `init()` only when `role == .phone`. `deinit` removes the token
//       (harmless on watch where the token is nil).
//    3. Forwarded `pumpManager: PumpManager?` accessor — needed by the
//       watch-side algorithm-driver wiring; harmless on iOS (the cast
//       still works there). Lifted unconditionally.
//    4. `.pairingHandoff` handling: the watch additionally calls
//       `policyEngine.markCachedPodStateAge(Date())` after caching. This
//       is a freshness marker for takeover safety; calling it on the
//       phone is harmless (the field exists; the phone never takes over
//       via this path). Lifted unconditionally.
//    5. Lazy pump-manager construction on `.watchDriver` (watch-only).
//       Closure-injected at init via `makeWatchSidePumpManager`; the
//       phone passes nil and the gate `role == .watch && case
//       .watchDriver = state && pumpManager == nil && closure != nil`
//       prevents accidental phone-side instantiation.
//
//  The B.6 race-hardening notifyUI ordering (publish handoffState LAST,
//  after ownership/policy updates) is unified to the watch's stricter
//  ordering on both sides — Phase 1 discovery confirmed iOS has no sink
//  dependent on the earlier ordering, and the watch's ordering is safer.
//

import Foundation
import LoopKit  // for `PumpManager` (forwarded accessor)
import Combine
import os.log

@MainActor
public final class HandoffOrchestrator: ObservableObject {

    /// Shared accessor populated by LoopAppManager / ExtensionDelegate at
    /// launch. SwiftUI views read this to observe handoff state, and the
    /// PhoneWatchSessionCoordinator's `orchestratorAccessor` is wired to it
    /// (used for split-brain detection).
    public static weak var shared: HandoffOrchestrator?

    /// log channel for command-gate effect transitions and split-brain
    /// detection.
    private let log = OSLog(category: "HandoffOrchestrator")

    @Published public private(set) var handoffState: HandoffState
    @Published public var settings: HandoffSettings

    /// User defaults used for settings persistence. Mutable for tests;
    /// production uses the App Group suite.
    public var userDefaults: UserDefaults

    private let role: HandoffRole
    private var coordinator: PhoneWatchSessionCoordinator
    private var stateMachine: HandoffStateMachine
    private var policyEngine: HandoffPolicyEngine
    private var shadowScheduler: ShadowStateScheduler

    private var cancellables: Set<AnyCancellable> = []
    private var scheduledTimers: [UUID: Task<Void, Never>] = [:]

    /// 60s debounce timer for marking phone-stable. When reachability flips
    /// on, we wait 60s before declaring "stable since", to avoid flapping
    /// during BLE reconnect storms. If reachability flips off in the
    /// interim, the timer is cancelled and stable-since is cleared.
    private var phoneStableDebounce: Task<Void, Never>?

    /// B.5.2 Issue #3b: token returned by the closure-based observer for
    /// `.NSSystemTimeZoneDidChange`. Held so `deinit` can remove it
    /// explicitly (closure observers are not removed by
    /// `removeObserver(self)` because the observer object is the returned
    /// token, not `self`). App-lifetime scoped — `deinit` only fires at
    /// app termination in production. Phone-only; nil on watch.
    private var systemTZObserver: NSObjectProtocol?

    /// debounce window matches HandoffPolicyEngine.absenceThreshold (60s).
    /// Tests can override via the optional `phoneStableDebounceOverride`
    /// init parameter.
    private static let defaultPhoneStableDebounceSeconds: TimeInterval = 60
    private let phoneStableDebounceSeconds: TimeInterval

    /// BLE ownership coordinator. Exposed (public) so call sites can
    /// read/write the commandsAllowed flag directly (split-brain
    /// demotion + unit tests).
    public let ownership: OmniBLEOwnership

    /// B.3.a Phase 6: returns the current settings snapshot for sync to the
    /// watch. Injected at init via closure so the orchestrator stays
    /// decoupled from LoopDataManager / ServicesManager. Phone-only;
    /// returns nil when not yet ready. Watch passes nil — `emitSettingsSync()`
    /// no-ops there.
    private let settingsSyncProvider: (() -> PhoneWatchSettingsSync?)?

    /// Watch-only closure to lazily construct the watch-side
    /// `OmniBLEPumpManager` on first `.watchDriver` transition. Phone
    /// passes nil (the phone's pump manager is wired in eagerly via the
    /// `pumpManager` init parameter). The closure typically reads
    /// `WatchSettingsCache.shared` to seed the basal schedule and
    /// max-temp-basal rate; podState is hydrated post-construction by
    /// `OmniBLEOwnership.acquireBLE()` from the cached pairing payload.
    private let makeWatchSidePumpManager: (() -> OmniBLEPumpManager)?

    /// dedup guard. Phone bails on `emitSettingsSync()` when the provider
    /// yields a payload byte-identical to the last one we sent. Cleared in
    /// `stop()` so a fresh `start()` always emits at least once.
    /// Watch never mutates this (watch's `settingsSyncProvider` is nil so
    /// `emitSettingsSync()` exits early).
    private var lastEmittedSync: PhoneWatchSettingsSync?

    /// replaces the previous `lastReceivedPayload` field — accessor
    /// forwards to ownership's cache (single source of truth).
    public var cachedPayload: OmniBLEHandoffPayload? { ownership.cachedPayload }

    /// forwarded accessor for the lazily-constructed (watch) or
    /// eagerly-injected (iOS) OmniBLEPumpManager, typed as `PumpManager`
    /// (LoopKit) since that's what the algorithm enacts on. The runtime
    /// cast `OmniBLEPodOwner? -> PumpManager?` is safe because the concrete
    /// type is always `OmniBLEPumpManager` (which conforms to both).
    public var pumpManager: PumpManager? { ownership.pumpManager as? PumpManager }

    /// Forwarded from the state machine. Capped at 10 (state machine
    /// enforces).
    public var transitionLog: [HandoffTransitionRecord] {
        stateMachine.transitionLog
    }

    public init(role: HandoffRole,
                coordinator: PhoneWatchSessionCoordinator,
                stateMachine: HandoffStateMachine,
                policyEngine: HandoffPolicyEngine,
                shadowScheduler: ShadowStateScheduler,
                userDefaults: UserDefaults = HandoffSettings.appGroupDefaults,
                pumpManager: OmniBLEPodOwner? = nil,
                settingsSyncProvider: (() -> PhoneWatchSettingsSync?)? = nil,
                makeWatchSidePumpManager: (() -> OmniBLEPumpManager)? = nil,
                phoneStableDebounceOverride: TimeInterval? = nil) {
        self.role = role
        self.coordinator = coordinator
        self.stateMachine = stateMachine
        self.policyEngine = policyEngine
        self.shadowScheduler = shadowScheduler
        self.userDefaults = userDefaults
        self.handoffState = stateMachine.state
        self.settings = HandoffSettings.load(from: userDefaults)
        self.ownership = OmniBLEOwnership(
            role: role,
            pumpManager: pumpManager,
            appGroupDefaults: userDefaults,
            initialState: stateMachine.state
        )
        self.settingsSyncProvider = settingsSyncProvider
        self.makeWatchSidePumpManager = makeWatchSidePumpManager
        self.phoneStableDebounceSeconds = phoneStableDebounceOverride
            ?? Self.defaultPhoneStableDebounceSeconds

        // observe phone-side time-zone changes (iOS posts this when the
        // user crosses a zone boundary, when Settings -> General -> Date &
        // Time changes, or when the carrier reports a TZ change). Trigger
        // a fresh sync emission so the watch picks up the new
        // TimeZone.current identifier promptly instead of lagging until
        // the next settings change. Closure-based observer pattern avoids
        // the `@objc` complication; `[weak self]` defends against retain
        // cycles even though the orchestrator is app-lifetime-scoped
        // (owned by LoopAppManager). Phone-only — the watch reads TZ from
        // the sync stream.
        if role == .phone {
            self.systemTZObserver = NotificationCenter.default.addObserver(
                forName: .NSSystemTimeZoneDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.notifySettingsChanged()
            }
        }
    }

    deinit {
        // explicit removal of the closure observer (token-based;
        // `removeObserver(self)` would not match it because the observer
        // object is the returned token, not `self`). Watch path is a no-op
        // since the token is nil.
        if let observer = systemTZObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func start() {
        coordinator.onHandoffMessage = { [weak self] message in
            Task { @MainActor in self?.handleIncoming(message: message) }
        }
        shadowScheduler.setFire { [weak self] in
            guard let self else { return }
            let effects = self.stateMachine.handle(.shadowStateRefreshDue)
            self.execute(effects)
        }
        policyEngine.start()
        shadowScheduler.start()

        // seed initial owner state for the policy engine. The state machine
        // starts in .phoneDriver, so the phone is the initial owner on
        // both roles.
        policyEngine.markCurrentOwner(.phone)

        // subscribe to reachability changes. Flip-on starts a 60s debounce;
        // flip-off immediately clears stable-since.
        coordinator.$isCounterpartReachable
            .removeDuplicates()
            .sink { [weak self] reachable in
                guard let self else { return }
                self.handleReachabilityChanged(reachable)
            }
            .store(in: &cancellables)

        // B.3.a Phase 6 — trigger point 1: emit settings on WCSession
        // connect (phone only — settings-sync provider is nil on the
        // watch). The coordinator's `start()` has already been called by
        // the time the orchestrator starts, so we fire once immediately on
        // a background tick to avoid blocking init while also racing any
        // pending WCSession activation. Fire-and-forget; the watch will
        // update its cache.
        Task { @MainActor [weak self] in self?.emitSettingsSync() }
    }

    public func stop() {
        coordinator.onHandoffMessage = nil
        policyEngine.stop()
        shadowScheduler.stop()
        scheduledTimers.values.forEach { $0.cancel() }
        scheduledTimers.removeAll()
        phoneStableDebounce?.cancel()
        phoneStableDebounce = nil
        cancellables.removeAll()
        // clear the dedup cache so a subsequent start() always emits at
        // least once (the watch may have lost the cached value across an
        // app restart).
        lastEmittedSync = nil
    }

    public func userRequestHandoff(to target: HandoffOwner) {
        // record the user activity so the policy engine's
        // 30s user-activity-quiet window kicks in.
        policyEngine.markUserInteractedAt(Date())
        let effects = stateMachine.handle(.userRequestedHandoff(target: target))
        execute(effects)
    }

    public func updateSettings(_ new: HandoffSettings) {
        settings = new
        try? new.save(to: userDefaults)
        policyEngine.updateSettings(new)
    }

    public func dismissRecovering() {
        let effects = stateMachine.handle(.manualRecoveryDismiss)
        execute(effects)
    }

    public func handleIncoming(message: PhoneWatchMessage) {
        switch message {
        case .heartbeat:
            return
        case .modeSwitch(let ms):
            execute(stateMachine.handle(.incomingModeSwitch(ms)))
        case .pairingHandoff(let ph):
            execute(stateMachine.handle(.incomingPairingHandoff(ph)))
            if let decoded = try? JSONDecoder().decode(OmniBLEHandoffPayload.self,
                                                       from: ph.pairingPayload) {
                ownership.cachePayload(decoded)   // B.2.e (replaces lastReceivedPayload assignment)
                // mark cached pod state freshness so the policy engine's
                // takeover safety gate knows the payload is recent. This
                // was watch-only previously; lifting it unconditionally is
                // benign on the phone (phone never auto-takes-over via
                // this path; the field exists either way).
                policyEngine.markCachedPodStateAge(Date())
            }
        case .settingsSync:
            // Settings sync is phone -> watch only. Watch coordinator
            // updates the cache via closure injection; the orchestrator
            // has nothing to do here. Phone never receives one.
            break
        case .algorithmStateSnapshot:
            // Snapshot routing is owned by PhoneWatchSessionCoordinator
            // (cache update via closure injection). The orchestrator has
            // nothing to do here on either side.
            break
        case .algorithmStateSnapshotPointer:
            // pointer -> inline rewrap happens at the ExtensionDelegate
            // edge before the transport decodes; the orchestrator never
            // sees pointers. No-op to keep the switch exhaustive.
            break
        }
    }

    /// B.3.a Phase 6: emit settings sync via trigger point 2 (settings
    /// change). As of B.5.2 Phase 4, the sole production caller is the
    /// iOS `.NSSystemTimeZoneDidChange` observer in `init(...)` — there
    /// is no LoopSettings-change observer wired up yet. A future
    /// LoopSettings observer (e.g. on `LoopDataManager.didUpdate*`) should
    /// also route through here. Fire-and-forget; debounce is the caller's
    /// responsibility. Phone-only path; on watch the
    /// `settingsSyncProvider` is nil so `emitSettingsSync()` exits early.
    public func notifySettingsChanged() {
        emitSettingsSync()
    }

    /// Test-only injection point.
    public func injectStateMachine(_ machine: HandoffStateMachine) {
        stateMachine = machine
        handoffState = machine.state
    }

    /// reachability change handler. On flip-on, schedule a 60s debounce ->
    /// mark phone stable. On flip-off, cancel the debounce and clear
    /// stable-since immediately.
    @MainActor
    private func handleReachabilityChanged(_ reachable: Bool) {
        phoneStableDebounce?.cancel()
        if !reachable {
            policyEngine.markPhoneStableSince(nil)
            return
        }
        let debounce = phoneStableDebounceSeconds
        phoneStableDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Re-check reachability after the actor hop: defends
                // against the window where reachability flipped off during
                // the sleep but the off-callback hasn't been processed yet.
                if self.coordinator.isReachable {
                    self.policyEngine.markPhoneStableSince(Date())
                }
            }
        }
    }

    /// surfaced (public) so unit tests can directly invoke the side-effect
    /// set under test (e.g. `.stopIssuingPodCommands`) without having to
    /// drive a full state-machine event sequence.
    public func execute(_ effects: [HandoffSideEffect]) {
        for effect in effects {
            switch effect {
            case .sendModeSwitch(let ms):
                coordinator.sendModeSwitch(ms)
            case .sendPairingHandoff(let ph):
                coordinator.sendPairingHandoff(fillPayload(ph))   // B.2.e
            case .sendSettingsSync(let sync):
                // Phone-only emission via state machine
                // (e.g. .handoffPending -> .phoneToWatch). Watch's state
                // machine does not emit this, but if it ever did the
                // coordinator's send is a thin wrapper over transport.queue
                // so a stray send is harmless.
                coordinator.sendSettingsSync(sync)
            case .scheduleTimeout(let id, let delay):
                scheduleTimeout(id: id, after: delay)
            case .stopIssuingPodCommands:
                // gate pod commands during handoff transitions.
                ownership.commandsAllowed = false
                log.default("commandsAllowed=false (handoff in progress)")
            case .resumeIssuingPodCommands:
                ownership.commandsAllowed = true
                log.default("commandsAllowed=true (handoff complete)")
            case .recordTransitionInLog:
                break
            case .notifyUI(let state):
                // B.6 race hardening: do all dependent-state mutations
                // BEFORE assigning handoffState. The @Published handoffState
                // fires Combine sinks (in ExtensionDelegate / observers)
                // that read ownership.pumpManager. If we set handoffState
                // first, the sink could (depending on scheduler) observe
                // the lazy-init NOT having happened yet, causing the
                // algorithm driver to be constructed with pumpManager: nil
                // and suppressing the first dose.
                //
                // Order: lazy-init pump manager (watch only) ->
                // ownership.update -> policy engine mark -> publish
                // handoffState LAST (triggers downstream).

                // lazy-instantiate OmniBLEPumpManager on first .watchDriver
                // (watch-only — phone wires its pump manager eagerly at
                // init). Strictly gated on role + state + closure presence
                // so a missing closure on the watch (test contexts) or a
                // stray phone-side pass-through is a no-op.
                if role == .watch,
                   case .watchDriver = state,
                   ownership.pumpManager == nil,
                   let make = makeWatchSidePumpManager {
                    let pm = make()
                    ownership.setPumpManager(pm)
                }
                ownership.update(state: state)   // B.2.e
                // mark current owner on every state transition so the
                // policy engine knows whose perspective to evaluate from.
                if let owner = state.currentOwner {
                    policyEngine.markCurrentOwner(owner)
                }
                // B.3.a Phase 6 — trigger point 3: emit on handoff
                // transition entering .handoffPending(.phoneToWatch). No-op
                // on watch since `emitSettingsSync()` early-exits when the
                // settings-sync provider is nil.
                if case .handoffPending(direction: .phoneToWatch, _, _) = state {
                    emitSettingsSync()
                }
                // Publish handoffState LAST — triggers downstream sinks
                // that depend on the now-current ownership + policy state.
                handoffState = state
            }
        }
    }

    /// B.3.a Phase 6: builds a `PhoneWatchSettingsSync` from the provider
    /// closure and queues it via the coordinator. No-op when the provider
    /// is nil (watch role, or phone before settings-sync is wired) or
    /// returns nil (settings not yet available).
    public func emitSettingsSync() {
        guard let provider = settingsSyncProvider,
              let sync = provider() else { return }
        // skip if the payload is unchanged since our last emission.
        // PhoneWatchSettingsSync is Equatable, so this is a cheap
        // structural compare that saves CPU + a WCSession queue slot when
        // multiple change-fanout sources fire in quick succession.
        guard sync != lastEmittedSync else {
            log.default("emitSettingsSync skipped: payload unchanged")
            return
        }
        lastEmittedSync = sync
        coordinator.sendSettingsSync(sync)
    }

    private func scheduleTimeout(id: UUID, after delay: TimeInterval) {
        scheduledTimers[id]?.cancel()
        scheduledTimers[id] = Task { [weak self, delay, id] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                self.execute(self.stateMachine.handle(.transitionDeadlineReached(transitionId: id)))
            }
        }
    }

    /// Fills the pairing-handoff payload with the current PodState
    /// (serialized via OmniBLEHandoffPayload's PropertyListSerialization
    /// helper) before the message goes out over WCSession.
    private func fillPayload(_ template: PhoneWatchPairingHandoff) -> PhoneWatchPairingHandoff {
        guard let pumpManager = ownership.pumpManager as? OmniBLEPumpManager,
              let podState = pumpManager.state.podState
        else {
            return template   // empty payload — counterpart will see no LTK
        }
        do {
            let payload = try OmniBLEHandoffPayload(podState: podState)
            let serialized = try payload.encoded()
            return PhoneWatchPairingHandoff(
                protocolVersion: template.protocolVersion,
                sentAt: template.sentAt,
                podId: template.podId,
                pairingPayload: serialized,
                validUntil: template.validUntil,
                transitionId: template.transitionId
            )
        } catch {
            return template
        }
    }
}

// MARK: - PhoneWatchOrchestratorAccessor conformance

/// Lets the OmniBLE-side `PhoneWatchSessionCoordinator` read the
/// orchestrator's current handoff state (for heartbeat.claimedOwner
/// population) and trigger split-brain demotion. Phone side:
/// `splitBrainDemoteSelf()` is unreachable in practice (the phone-side
/// branch of the lifted coordinator's split-brain switch only logs an
/// advisory), but conforming for symmetry keeps the wire-up identical
/// across roles. Watch side: `splitBrainDemoteSelf()` is the load-bearing
/// pediatric-safety path — sets `commandsAllowed = false` immediately and
/// emits a `userRequestHandoff(.phone)` so the state machine reverts.
extension HandoffOrchestrator: PhoneWatchOrchestratorAccessor {
    public var currentHandoffState: HandoffState { handoffState }

    public func splitBrainDemoteSelf() {
        ownership.commandsAllowed = false
        userRequestHandoff(to: .phone)
    }
}
