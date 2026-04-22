//
//  ReservoirLevelHighlightState.swift
//  OmniBLE
//
//  Promoted from PumpManagerUI into core OmniBLE so watchOS consumers
//  (which do not link PumpManagerUI) can observe reservoir highlight
//  state on `OmniBLEPumpManager.reservoirLevelHighlightState`.
//

import Foundation

public enum ReservoirLevelHighlightState: String, Equatable {
    case normal
    case warning
    case critical
}
