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
}
