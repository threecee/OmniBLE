//
//  OmniBLEOwnership.swift
//  OmniBLE (Common)
//
// Listens for HandoffOrchestrator state changes (pushed via update(state:))
//  and triggers OmniBLEPumpManager BLE acquire/release on transitions that change
//  which side owns the pod.
//
//  Lives in OmniBLE/Common (alongside HandoffStateMachine, HandoffSettings, etc.)
//  so both Loop iOS and the WatchApp Extension share the same implementation.
//

import Foundation
import os.log
import Combine

// MARK: - Protocol

/// The three BLE-control methods that OmniBLEOwnership calls on the pump manager.
/// Expressed as a protocol so unit tests can inject a mock without instantiating
/// a real OmniBLEPumpManager (which would trigger CBCentralManager creation).
public protocol OmniBLEPodOwner: AnyObject {
    func restorePodState(_ podState: PodState)
    func connectToActivePod()
    func disconnectFromActivePod()
}

// MARK: - Conformance

extension OmniBLEPumpManager: OmniBLEPodOwner {}

// MARK: - OmniBLEOwnership

@MainActor
public final class OmniBLEOwnership {
    public let role: HandoffRole

    public private(set) var pumpManager: OmniBLEPodOwner?
    public private(set) var cachedPayload: OmniBLEHandoffPayload?

    /// Gate flag for pod commands during handoff transitions.
    /// Set to false on `.stopIssuingPodCommands` effect; true on
    /// `.resumeIssuingPodCommands`. Wired into `OmniBLEPumpManager` via
    /// `commandsAllowedCheck` callback (see `wireCommandsCallback`).
    @Published public var commandsAllowed: Bool = true

    private let appGroupDefaults: UserDefaults
    private var lastSeenState: HandoffState

    private static let payloadKey = "com.LoopKit.OmniBLE.cachedHandoffPayload"
    private let log = OSLog(category: "OmniBLEOwnership")

    public init(
        role: HandoffRole,
        pumpManager: OmniBLEPodOwner? = nil,
        appGroupDefaults: UserDefaults = HandoffSettings.appGroupDefaults,
        initialState: HandoffState = .phoneDriver
    ) {
        self.role = role
        self.pumpManager = pumpManager
        self.appGroupDefaults = appGroupDefaults
        self.lastSeenState = initialState
        self.cachedPayload = OmniBLEOwnership.loadCachedPayload(from: appGroupDefaults)
        // wire callback if pumpManager supplied at init (iOS path).
        if let pumpManager = pumpManager {
            wireCommandsCallback(into: pumpManager)
        }
    }

    // MARK: - Public API

    public var iAmDriver: Bool {
        return ownerOf(state: lastSeenState) == role.asOwner
    }

    /// Called by HandoffOrchestrator on every state change.
    public func update(state: HandoffState) {
        let priorState = lastSeenState
        lastSeenState = state
        handleTransition(from: priorState, to: state)
    }

    /// Called by HandoffOrchestrator when a pairing-handoff message arrives
    /// over WCSession. Stores the decoded payload so it's available the next
    /// time this side transitions to driver and needs to hydrate PodState.
    public func cachePayload(_ payload: OmniBLEHandoffPayload) {
        cachedPayload = payload
        OmniBLEOwnership.savePayload(payload, to: appGroupDefaults)
        log.default("cached payload for pod %{public}@ (%d bytes)",
                    payload.podSerial, payload.serializedPodState.count)
    }

    /// Watch-side: orchestrator constructs OmniBLEPumpManager lazily on first
    /// transition to .watchDriver and calls this setter, then update(state:).
    public func setPumpManager(_ pumpManager: OmniBLEPodOwner) {
        self.pumpManager = pumpManager
        wireCommandsCallback(into: pumpManager)
    }

    /// install the commandsAllowed callback into the pump manager.
    /// Called from setPumpManager (watch path) and init (iOS path). Cast
    /// through to OmniBLEPumpManager since the gate lives on the concrete
    /// class — OmniBLEPodOwner only has BLE-control methods.
    private func wireCommandsCallback(into podOwner: OmniBLEPodOwner) {
        if let pumpManager = podOwner as? OmniBLEPumpManager {
            pumpManager.commandsAllowedCheck = { [weak self] in
                self?.commandsAllowed ?? true
            }
        }
        // If podOwner is a test mock (not OmniBLEPumpManager), skip — the
        // mock should expose its own way to verify "would have suppressed."
    }

    // MARK: - Internal transition logic

    private func handleTransition(from prior: HandoffState, to next: HandoffState) {
        let priorOwner = ownerOf(state: prior)
        let nextOwner = ownerOf(state: next)
        let myOwner = role.asOwner

        if priorOwner == myOwner && nextOwner != myOwner {
            log.default("transition: I (%{public}@) am no longer driver — releasing BLE",
                        role == .phone ? "phone" : "watch")
            releaseBLE()
        } else if priorOwner != myOwner && nextOwner == myOwner {
            log.default("transition: I (%{public}@) am now driver — acquiring BLE",
                        role == .phone ? "phone" : "watch")
            acquireBLE()
        }
    }

    private func acquireBLE() {
        guard let pumpManager = pumpManager else {
            log.error("acquireBLE() called but no pumpManager configured (wiring bug)")
            return
        }
        if let payload = cachedPayload, payload.isValid(now: Date()) {
            do {
                let restoredPodState = try payload.decodedPodState()
                pumpManager.restorePodState(restoredPodState)
                log.default("acquireBLE: restored pod state from cached payload (pod %{public}@)",
                            payload.podSerial)
            } catch {
                log.error("acquireBLE: failed to decode cached payload: %{public}@",
                          String(describing: error))
            }
        } else {
            log.default("acquireBLE: no valid cached payload — pumpManager uses existing in-memory state")
        }
        pumpManager.connectToActivePod()
    }

    private func releaseBLE() {
        guard let pumpManager = pumpManager else {
            log.default("releaseBLE: no pumpManager (already released)")
            return
        }
        pumpManager.disconnectFromActivePod()
        log.default("releaseBLE: disconnected from pod")
    }

    private func ownerOf(state: HandoffState) -> HandoffOwner {
        switch state {
        case .phoneDriver: return .phone
        case .watchDriver: return .watch
        case .recovering(_, let last): return last
        case .handoffPending(.phoneToWatch, _, _): return .phone
        case .handoffPending(.watchToPhone, _, _): return .watch
        }
    }

    // MARK: - Cached payload persistence

    private static func loadCachedPayload(from defaults: UserDefaults) -> OmniBLEHandoffPayload? {
        return defaults.codableValue(forKey: payloadKey, as: OmniBLEHandoffPayload.self)
    }

    private static func savePayload(_ payload: OmniBLEHandoffPayload, to defaults: UserDefaults) {
        defaults.set(codable: payload, forKey: payloadKey)
    }
}
