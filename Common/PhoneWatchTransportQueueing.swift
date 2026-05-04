//
//  PhoneWatchTransportQueueing.swift
//  OmniBLE
//
//  Minimal queueing surface used by callers that only need to enqueue
//  outbound PhoneWatchMessages and don't care about the rest of the
//  transport's API. Production: WCSessionPhoneWatchTransport conforms.
//  Tests: a fake conformer collects queued messages without WCSession.
//

import Foundation

public protocol PhoneWatchTransportQueueing: AnyObject {
    func queueMessage(_ message: PhoneWatchMessage)
}
