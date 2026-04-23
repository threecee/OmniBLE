//
//  HandoffEvent.swift
//  OmniBLE
//
//  Inputs to the HandoffStateMachine. Each event represents one thing that
//  could change the machine's state.
//

import Foundation

public enum HandoffEvent: Equatable {
    /// User tapped a manual-trigger button in the UI.
    case userRequestedHandoff(target: HandoffOwner)

    /// Policy engine emitted an automatic trigger after thresholds were met.
    case policyRequestedHandoff(target: HandoffOwner)

    /// Incoming WCSession message from B.2.c.
    case incomingModeSwitch(PhoneWatchModeSwitch)

    /// Incoming WCSession message from B.2.c.
    case incomingPairingHandoff(PhoneWatchPairingHandoff)

    /// 30-second deadline for a HandoffPending transition reached.
    case transitionDeadlineReached(transitionId: UUID)

    /// 5-min shadow refresh ticker fired (driver side only).
    case shadowStateRefreshDue

    /// User dismissed the Recovering banner from UI.
    case manualRecoveryDismiss
}
