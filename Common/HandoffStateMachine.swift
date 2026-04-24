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

    public private(set) var state: HandoffState
    public private(set) var lastKnownOwner: HandoffOwner
    public private(set) var transitionLog: [HandoffTransitionRecord] = []

    public static let transitionTimeout: TimeInterval = 30
    public static let logCapacity: Int = 10

    private let role: HandoffRole

    public init(initialState: HandoffState = .phoneDriver, role: HandoffRole) {
        self.state = initialState
        self.role = role
        switch initialState {
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
            // Incoming handoff request: someone (phone or watch user) triggered a
            // handover to the watch. We transition to handoffPending using the
            // incoming transitionId (so subsequent confirm references same id).
            // `ms.requestedBy` is informational only — the transition is the same
            // regardless of which side initiated.
            effects = enterPending(direction: .phoneToWatch,
                                   transitionId: ms.transitionId,
                                   now: now)

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
            // Symmetric to the phoneDriver → watchDriver case above. Accept handover
            // requests from either side; `ms.requestedBy` is informational only.
            effects = enterPending(direction: .watchToPhone,
                                   transitionId: ms.transitionId,
                                   now: now)

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
            effects = [.notifyUI(state: state)]
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
