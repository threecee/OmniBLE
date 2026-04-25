//
//  MessageType.swift
//  OmniBLETests
//
//  Mirror of bridge.MsgType in pkg/bridge/framing.go. Values MUST match
//  the Go side exactly; out-of-sync values cause silent protocol breakage.
//
//  Named BridgeMessageType to avoid collision with the OmniBLE module's
//  existing MessageType enum (Bluetooth/MessagePacket.swift).
//

import Foundation

enum BridgeMessageType: UInt8 {
    // Central -> Pod (Swift -> Go)
    case connect       = 0x01
    case disconnect    = 0x02
    case subscribe     = 0x03
    case unsubscribe   = 0x04
    case write         = 0x05
    case readRequest   = 0x06

    // Pod -> Central (Go -> Swift)
    case connectAck    = 0x81
    case disconnectAck = 0x82
    case notify        = 0x83
    case readResponse  = 0x84
    case error         = 0x85

    // Debug-only
    case debugGetLastCommand = 0xF0
    case debugLastCommand    = 0xF1
}
