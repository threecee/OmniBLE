//
//  HandoffSideEffect.swift
//  OmniBLE
//
//  Outputs of HandoffStateMachine.handle(_:). The state machine is pure;
//  consumers (orchestrator) execute these effects.
//

import Foundation

public enum HandoffSideEffect: Equatable {
    case sendModeSwitch(PhoneWatchModeSwitch)
    case sendPairingHandoff(PhoneWatchPairingHandoff)
    case sendSettingsSync(PhoneWatchSettingsSync)
    case scheduleTimeout(transitionId: UUID, after: TimeInterval)
    case stopIssuingPodCommands
    case resumeIssuingPodCommands
    case recordTransitionInLog(HandoffTransitionRecord)
    case notifyUI(state: HandoffState)

    /// B.11.3: orchestrator must publish a devicestatus document with
    /// `currentDriver: incomingDriver`. Under Option D the orchestrator
    /// fires `RemoteCareUploader.upload(for: .dose)` (fire-and-forget)
    /// and immediately feeds `.rendezvousPublishCompleted` back into the
    /// state machine — the upload is advisory; idempotency on the new
    /// driver's first iteration is the load-bearing safety property.
    case publishRendezvous(transitionId: UUID, incomingDriver: HandoffOwner)
}
