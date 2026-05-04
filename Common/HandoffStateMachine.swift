//
//  HandoffStateMachine.swift
//  OmniBLE
//
//  Pure state machine: takes events, returns side-effects, mutates internal
//  state and log. The orchestrator (Loop iOS / LoopWatchApp side) executes
//  the returned side-effects (sending WCSession messages, scheduling timers,
//  etc.). This separation keeps the machine deterministic and trivially
//  unit-testable.
//

import Foundation
import os.log

public final class HandoffStateMachine {

    /// didSet persists every state transition (including
    /// transient .handoffPending states) to App Group UserDefaults so the
    /// state machine can recover from crash mid-handoff.
    public private(set) var state: HandoffState {
        didSet {
            HandoffStatePersistence.save(state, to: appGroupDefaults)
        }
    }
    public private(set) var lastKnownOwner: HandoffOwner
    public private(set) var transitionLog: [HandoffTransitionRecord] = []

    public static let transitionTimeout: TimeInterval = 30
    public static let logCapacity: Int = 10

    private let role: HandoffRole
    private let appGroupDefaults: UserDefaults

    /// B.11.3: log channel for HandoffPending entry/exit timeline so HV-1
    /// can correlate state transitions with rendezvous-publish timing.
    private let log = OSLog(category: "HandoffStateMachine")

    public init(initialState: HandoffState = .phoneDriver,
                role: HandoffRole,
                appGroupDefaults: UserDefaults = HandoffSettings.appGroupDefaults) {
        self.appGroupDefaults = appGroupDefaults
        self.role = role
        // restore persisted state if available; otherwise
        // use supplied initialState. Note: didSet on `state` doesn't fire
        // during init — first persistence happens on the first transition
        // after init. (No double-write at construction; cleaner.)
        let effectiveInitial: HandoffState
        if let restored = HandoffStatePersistence.load(from: appGroupDefaults) {
            // B.8.2 M3: a restored .handoffPending state is *by definition*
            // not recoverable across an app-restart boundary. The 30-second
            // deadline can't be trusted across crash boundaries (wall-clock
            // can drift, be NTP-corrected, or be manually set backward).
            // Treat any restored pending as expired and surface a recovery
            // banner. Annoyance over safety — a user who restarts within
            // the legitimate 30s window sees recovery instead of completion,
            // which is ergonomically worse but makes the stuck-pending
            // failure mode impossible. (Vacuously closes M2: no path leaves
            // init in .handoffPending, so no .scheduleTimeout re-emission
            // is needed.)
            if case .handoffPending(direction: let dir, _, _, _) = restored {
                let recoveredOwner: HandoffOwner = dir.origin
                effectiveInitial = .recovering(reason: .restoredExpiredPending,
                                                lastKnownOwner: recoveredOwner)
                // Clear stale persisted state so the next save (on first
                // transition) writes the recovery state cleanly.
                HandoffStatePersistence.clear(from: appGroupDefaults)
            } else {
                effectiveInitial = restored
            }
        } else {
            effectiveInitial = initialState
        }
        self.state = effectiveInitial
        switch effectiveInitial {
        case .phoneDriver: self.lastKnownOwner = .phone
        case .watchDriver: self.lastKnownOwner = .watch
        case .recovering(_, let last): self.lastKnownOwner = last
        case .handoffPending(.phoneToWatch, _, _, _): self.lastKnownOwner = .phone
        case .handoffPending(.watchToPhone, _, _, _): self.lastKnownOwner = .watch
        }
    }

    /// Process an event; returns side-effects to execute. State and log mutate.
    public func handle(_ event: HandoffEvent, now: Date = Date()) -> [HandoffSideEffect] {
        let priorState = state
        let effects: [HandoffSideEffect]

        switch (state, event) {

        // MARK: Trigger from PhoneDriver
        case (.phoneDriver, .userRequestedHandoff(target: .watch)),
             (.phoneDriver, .policyRequestedHandoff(target: .watch)):
            effects = beginHandoff(direction: .phoneToWatch, now: now)

        case (.phoneDriver, .incomingModeSwitch(let ms))
            where ms.targetMode == .watchDriver:
            // Two-step transition in one event: pending (sends confirm modeSwitch back)
            // then immediately complete to .watchDriver. Closes the protocol gap from
            // B.2.d where the receiver-side would otherwise wait for an ack from the
            // initiator that never comes (the initiator transitions on receiving our
            // confirm; without this self-completion we'd time out on this side).
            // `ms.requestedBy` is informational only — the transition is the same
            // regardless of which side initiated.
            effects = enterPending(direction: .phoneToWatch,
                                   transitionId: ms.transitionId,
                                   now: now)
                    + completeHandoff(to: .watch, now: now)

        case (.phoneDriver, .shadowStateRefreshDue):
            effects = [.sendPairingHandoff(buildPairingHandoff(now: now,
                                                                transitionId: UUID()))]

        // MARK: From HandoffPending(phoneToWatch)
        case (.handoffPending(direction: .phoneToWatch, transitionId: let id, _, _),
              .incomingModeSwitch(let ms))
            where ms.transitionId == id && ms.targetMode == .watchDriver:
            effects = completeHandoff(to: .watch, now: now)

        case (.handoffPending(direction: .phoneToWatch, transitionId: let id, _, _),
              .incomingModeSwitch(let ms))
            where ms.transitionId == id && ms.targetMode != .watchDriver:
            effects = enterRecovering(reason: .rejectedByCounterpart, now: now)

        // MARK: Trigger from WatchDriver
        case (.watchDriver, .userRequestedHandoff(target: .phone)),
             (.watchDriver, .policyRequestedHandoff(target: .phone)):
            effects = beginHandoff(direction: .watchToPhone, now: now)

        case (.watchDriver, .incomingModeSwitch(let ms))
            where ms.targetMode == .phoneDriver:
            // Symmetric to the phoneDriver → watchDriver case above. Two-step
            // transition; receiver self-completes.
            effects = enterPending(direction: .watchToPhone,
                                   transitionId: ms.transitionId,
                                   now: now)
                    + completeHandoff(to: .phone, now: now)

        case (.watchDriver, .shadowStateRefreshDue):
            effects = [.sendPairingHandoff(buildPairingHandoff(now: now,
                                                                transitionId: UUID()))]

        // MARK: From HandoffPending(watchToPhone)
        case (.handoffPending(direction: .watchToPhone, transitionId: let id, _, _),
              .incomingModeSwitch(let ms))
            where ms.transitionId == id && ms.targetMode == .phoneDriver:
            effects = completeHandoff(to: .phone, now: now)

        case (.handoffPending(direction: .watchToPhone, transitionId: let id, _, _),
              .incomingModeSwitch(let ms))
            where ms.transitionId == id && ms.targetMode != .phoneDriver:
            effects = enterRecovering(reason: .rejectedByCounterpart, now: now)

        // MARK: HandoffPending — common: timeout matching the active transition id
        case (.handoffPending(_, transitionId: let id, _, _),
              .transitionDeadlineReached(let timeoutId))
            where id == timeoutId:
            effects = enterRecovering(reason: .timeoutWaitingForConfirmation, now: now)

        // MARK: B.11.3 — Pre-flip rendezvous publication outcomes
        // .rendezvousPublishCompleted: orchestrator just fired the
        // pre-flip devicestatus upload (fire-and-forget under Option D).
        // We flip the substate flag to true so HV-1 + UI can observe the
        // completed rendezvous step. transitionId guard defends against
        // late callbacks from a prior, aborted handoff.
        case (.handoffPending(direction: let dir,
                              transitionId: let id,
                              deadline: let deadline,
                              tokenRendezvousPublished: false),
              .rendezvousPublishCompleted(transitionId: let cid))
            where id == cid:
            state = .handoffPending(direction: dir,
                                    transitionId: id,
                                    deadline: deadline,
                                    tokenRendezvousPublished: true)
            log.default("rendezvousPublishCompleted: transitionId=%{public}@",
                        id.uuidString)
            // No notifyUI emission. The originating .userRequestedHandoff
            // already emitted notifyUI(.handoffPending(..., published:
            // false)) which the orchestrator processes AFTER
            // .publishRendezvous (the orchestrator's .publishRendezvous
            // handler runs first, fires the upload while still driver,
            // then feeds this event). The substate flag is consumed
            // primarily for HV-1 timeline + tests reading
            // `stateMachine.state` directly; the @Published handoffState
            // mirror need not flip a second time within the same effects
            // loop. If a future UI surface needs to react to the substate
            // flag flipping, expose a dedicated published property
            // (tokenRendezvousPublished: Bool) rather than re-emitting
            // notifyUI here.
            effects = []

        // .rendezvousPublishFailed: NOT emitted under current Option D
        // wiring (pre-flip publish is fire-and-forget, no failure
        // surfacing). The handler is retained for the additive structural
        // landing per plan + future surface area. If invoked it transitions
        // to .recovering(.rendezvousPublishFailed, ...) and re-emits
        // .resumeIssuingPodCommands so the surviving outgoing driver can
        // continue delivering.
        case (.handoffPending(_, transitionId: let id, _, _),
              .rendezvousPublishFailed(transitionId: let fid))
            where id == fid:
            effects = enterRecovering(reason: .rendezvousPublishFailed, now: now)
                    + [.resumeIssuingPodCommands]

        // MARK: From Recovering
        case (.recovering(_, lastKnownOwner: let owner), .manualRecoveryDismiss):
            state = (owner == .phone) ? .phoneDriver : .watchDriver
            // re-emit .resumeIssuingPodCommands for the
            // local side when it's the surviving owner, mirroring
            // completeHandoff's resumeIfMine pattern. Without this, the
            // surviving owner stays with commandsAllowed == false
            // indefinitely after the user dismisses the recovery banner.
            // Resume FIRST, then notify UI, so the UI sees commands
            // enabled when it renders.
            let resumeIfMine: [HandoffSideEffect] = (owner == role.asOwner)
                ? [.resumeIssuingPodCommands] : []
            effects = resumeIfMine + [.notifyUI(state: state)]
            recordTransition(from: priorState, to: state,
                             trigger: .userManual, now: now)
            return effects

        // MARK: All other (state, event) pairs are no-ops
        default:
            return []
        }

        // Log if state changed.
        if state != priorState {
            recordTransition(from: priorState, to: state,
                             trigger: triggerForEvent(event),
                             now: now)
        }

        return effects
    }

    // MARK: - Helpers

    private func triggerForEvent(_ event: HandoffEvent) -> HandoffTransitionTrigger {
        switch event {
        case .userRequestedHandoff: return .userManual
        case .policyRequestedHandoff: return .policyAutomatic
        case .incomingModeSwitch, .incomingPairingHandoff: return .messageFromCounterpart
        case .transitionDeadlineReached: return .timeout
        case .shadowStateRefreshDue: return .shadowRefresh
        case .manualRecoveryDismiss: return .userManual
        case .rendezvousPublishCompleted, .rendezvousPublishFailed: return .rendezvousOutcome
        }
    }

    private func beginHandoff(direction: HandoffDirection,
                              now: Date) -> [HandoffSideEffect] {
        let id = UUID()
        let deadline = now.addingTimeInterval(Self.transitionTimeout)
        state = .handoffPending(direction: direction,
                                transitionId: id,
                                deadline: deadline,
                                tokenRendezvousPublished: false)
        log.default("HandoffPending ENTRY (initiator): direction=%{public}@ transitionId=%{public}@ tokenRendezvousPublished=false",
                    direction.rawValue, id.uuidString)

        let modeSwitch = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: now,
            requestedBy: role == .phone ? .phone : .watch,
            targetMode: direction.destination == .watch ? .watchDriver : .phoneDriver,
            transitionId: id
        )
        let pairingHandoff = buildPairingHandoff(now: now, transitionId: id)

        // B.11.3: emit .publishRendezvous so the orchestrator fires the
        // pre-flip devicestatus upload with `currentDriver: incomingDriver`
        // BEFORE the BLE role flip. Receiver-side enterPending does NOT
        // emit this — only the initiating outgoing driver writes the
        // rendezvous (driver-only-writes invariant).
        return [
            .stopIssuingPodCommands,
            .sendPairingHandoff(pairingHandoff),
            .sendModeSwitch(modeSwitch),
            .scheduleTimeout(transitionId: id, after: Self.transitionTimeout),
            .publishRendezvous(transitionId: id, incomingDriver: direction.destination),
            .notifyUI(state: state)
        ]
    }

    private func enterPending(direction: HandoffDirection,
                              transitionId: UUID,
                              now: Date) -> [HandoffSideEffect] {
        let deadline = now.addingTimeInterval(Self.transitionTimeout)
        state = .handoffPending(direction: direction,
                                transitionId: transitionId,
                                deadline: deadline,
                                tokenRendezvousPublished: false)
        log.default("HandoffPending ENTRY (receiver): direction=%{public}@ transitionId=%{public}@",
                    direction.rawValue, transitionId.uuidString)
        let confirm = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: now,
            requestedBy: role == .phone ? .phone : .watch,
            targetMode: direction.destination == .watch ? .watchDriver : .phoneDriver,
            transitionId: transitionId
        )
        // Receiver-side does NOT emit .publishRendezvous — the initiating
        // outgoing driver owns the rendezvous publish (driver-only-writes).
        return [
            .stopIssuingPodCommands,
            .sendModeSwitch(confirm),
            .scheduleTimeout(transitionId: transitionId, after: Self.transitionTimeout),
            .notifyUI(state: state)
        ]
    }

    private func completeHandoff(to owner: HandoffOwner,
                                 now: Date) -> [HandoffSideEffect] {
        log.default("HandoffPending EXIT (success): newOwner=%{public}@", owner.rawValue)
        state = (owner == .phone) ? .phoneDriver : .watchDriver
        lastKnownOwner = owner
        let resumeIfMine: [HandoffSideEffect] = (owner == role.asOwner)
            ? [.resumeIssuingPodCommands] : []
        return resumeIfMine + [.notifyUI(state: state)]
    }

    private func enterRecovering(reason: HandoffRecoveryReason,
                                 now: Date) -> [HandoffSideEffect] {
        log.default("HandoffPending EXIT (recovering): reason=%{public}@", reason.rawValue)
        state = .recovering(reason: reason, lastKnownOwner: lastKnownOwner)
        return [.notifyUI(state: state)]
    }

    private func buildPairingHandoff(now: Date, transitionId: UUID) -> PhoneWatchPairingHandoff {
        // The state machine doesn't have access to PodState here; the orchestrator
        // populates pairingPayload before sending. We send an empty payload as a
        // placeholder; consumers are expected to attach the real payload.
        // (Tests verify the orchestrator's responsibility to fill this in.)
        PhoneWatchPairingHandoff(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: now,
            podId: "",
            pairingPayload: Data(),
            validUntil: now.addingTimeInterval(60),
            transitionId: transitionId
        )
    }

    private func recordTransition(from: HandoffState, to: HandoffState,
                                  trigger: HandoffTransitionTrigger, now: Date) {
        let record = HandoffTransitionRecord(
            timestamp: now,
            from: from.snapshot,
            to: to.snapshot,
            trigger: trigger
        )
        transitionLog.append(record)
        if transitionLog.count > Self.logCapacity {
            transitionLog.removeFirst(transitionLog.count - Self.logCapacity)
        }
    }
}
