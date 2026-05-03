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

public final class HandoffStateMachine {

    /// B.5 Issue #4: didSet persists every state transition (including
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

    public init(initialState: HandoffState = .phoneDriver,
                role: HandoffRole,
                appGroupDefaults: UserDefaults = HandoffSettings.appGroupDefaults) {
        self.appGroupDefaults = appGroupDefaults
        self.role = role
        // B.5 Issue #4: restore persisted state if available; otherwise
        // use supplied initialState. Note: didSet on `state` doesn't fire
        // during init — first persistence happens on the first transition
        // after init. (No double-write at construction; cleaner.)
        let effectiveInitial: HandoffState
        if let restored = HandoffStatePersistence.load(from: appGroupDefaults) {
            // B.8.1 Issue #3: a restored .handoffPending state whose
            // deadline is past must be converted to a safe recovery state.
            // Otherwise the machine wakes up still mid-handoff after the
            // 30s window has long closed, leaving ownership unresolved
            // and command suppression stuck.
            if case .handoffPending(direction: let dir, _, deadline: let deadline) = restored,
               deadline < Date() {
                let recoveredOwner: HandoffOwner = (dir == .phoneToWatch) ? .phone : .watch
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
        case .handoffPending(.phoneToWatch, _, _): self.lastKnownOwner = .phone
        case .handoffPending(.watchToPhone, _, _): self.lastKnownOwner = .watch
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
        case (.handoffPending(direction: .phoneToWatch, transitionId: let id, _),
              .incomingModeSwitch(let ms))
            where ms.transitionId == id && ms.targetMode == .watchDriver:
            effects = completeHandoff(to: .watch, now: now)

        case (.handoffPending(direction: .phoneToWatch, transitionId: let id, _),
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
        case (.handoffPending(direction: .watchToPhone, transitionId: let id, _),
              .incomingModeSwitch(let ms))
            where ms.transitionId == id && ms.targetMode == .phoneDriver:
            effects = completeHandoff(to: .phone, now: now)

        case (.handoffPending(direction: .watchToPhone, transitionId: let id, _),
              .incomingModeSwitch(let ms))
            where ms.transitionId == id && ms.targetMode != .phoneDriver:
            effects = enterRecovering(reason: .rejectedByCounterpart, now: now)

        // MARK: HandoffPending — common: timeout matching the active transition id
        case (.handoffPending(_, transitionId: let id, _),
              .transitionDeadlineReached(let timeoutId))
            where id == timeoutId:
            effects = enterRecovering(reason: .timeoutWaitingForConfirmation, now: now)

        // MARK: From Recovering
        case (.recovering(_, lastKnownOwner: let owner), .manualRecoveryDismiss):
            state = (owner == .phone) ? .phoneDriver : .watchDriver
            // B.8.1 Issue #2: re-emit .resumeIssuingPodCommands for the
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
        }
    }

    private func beginHandoff(direction: HandoffDirection,
                              now: Date) -> [HandoffSideEffect] {
        let id = UUID()
        let deadline = now.addingTimeInterval(Self.transitionTimeout)
        state = .handoffPending(direction: direction, transitionId: id, deadline: deadline)

        let modeSwitch = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: now,
            requestedBy: role == .phone ? .phone : .watch,
            targetMode: direction.destination == .watch ? .watchDriver : .phoneDriver,
            transitionId: id
        )
        let pairingHandoff = buildPairingHandoff(now: now, transitionId: id)

        return [
            .stopIssuingPodCommands,
            .sendPairingHandoff(pairingHandoff),
            .sendModeSwitch(modeSwitch),
            .scheduleTimeout(transitionId: id, after: Self.transitionTimeout),
            .notifyUI(state: state)
        ]
    }

    private func enterPending(direction: HandoffDirection,
                              transitionId: UUID,
                              now: Date) -> [HandoffSideEffect] {
        let deadline = now.addingTimeInterval(Self.transitionTimeout)
        state = .handoffPending(direction: direction, transitionId: transitionId, deadline: deadline)
        let confirm = PhoneWatchModeSwitch(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: now,
            requestedBy: role == .phone ? .phone : .watch,
            targetMode: direction.destination == .watch ? .watchDriver : .phoneDriver,
            transitionId: transitionId
        )
        return [
            .stopIssuingPodCommands,
            .sendModeSwitch(confirm),
            .scheduleTimeout(transitionId: transitionId, after: Self.transitionTimeout),
            .notifyUI(state: state)
        ]
    }

    private func completeHandoff(to owner: HandoffOwner,
                                 now: Date) -> [HandoffSideEffect] {
        state = (owner == .phone) ? .phoneDriver : .watchDriver
        lastKnownOwner = owner
        let resumeIfMine: [HandoffSideEffect] = (owner == role.asOwner)
            ? [.resumeIssuingPodCommands] : []
        return resumeIfMine + [.notifyUI(state: state)]
    }

    private func enterRecovering(reason: HandoffRecoveryReason,
                                 now: Date) -> [HandoffSideEffect] {
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
