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

    /// B.11.3: Pre-flip rendezvous devicestatus upload completed.
    /// Honored only when the carried `transitionId` matches the active
    /// `.handoffPending` transitionId (defends against late callbacks
    /// from a prior, aborted handoff). Sets the substate flag
    /// `tokenRendezvousPublished` to true.
    case rendezvousPublishCompleted(transitionId: UUID)

    /// B.11.3: Pre-flip rendezvous upload failed. Under Option D
    /// (Carl-decided), this event is NOT emitted in current production
    /// code: the pre-flip publish is fire-and-forget and never surfaces a
    /// failure. The case is retained additively for future surface area
    /// (and to keep the mechanical landing per plan); see
    /// `HandoffOrchestrator` for the rationale.
    case rendezvousPublishFailed(transitionId: UUID)
}
