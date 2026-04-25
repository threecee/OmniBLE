//
//  PodSimulatorBridgeTests.swift
//  OmniBLETests
//

import XCTest
@testable import OmniBLE

final class PodSimulatorBridgeTests: XCTestCase {

    func testFrameRoundTrip_emptyPayload() throws {
        let encoded = PodSimulatorBridge.encodeFrame(type: .connectAck, payload: Data())
        XCTAssertEqual(encoded, Data([0x81, 0x00, 0x00, 0x00, 0x00]))

        let (type, payload) = try PodSimulatorBridge.decodeFrame(from: encoded)
        XCTAssertEqual(type, .connectAck)
        XCTAssertEqual(payload, Data())
    }

    func testFrameRoundTrip_withPayload() throws {
        let inputBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let encoded = PodSimulatorBridge.encodeFrame(type: .write, payload: inputBytes)
        XCTAssertEqual(encoded, Data([0x05, 0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]))

        let (type, payload) = try PodSimulatorBridge.decodeFrame(from: encoded)
        XCTAssertEqual(type, .write)
        XCTAssertEqual(payload, inputBytes)
    }

    func testFrameDecode_truncatedHeader_throws() {
        XCTAssertThrowsError(try PodSimulatorBridge.decodeFrame(from: Data([0x05, 0x00, 0x00])))
    }

    func testFrameDecode_truncatedPayload_throws() {
        // Header says payload is 100 bytes; only 5 follow
        let buf = Data([0x05, 0x00, 0x00, 0x00, 0x64, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        XCTAssertThrowsError(try PodSimulatorBridge.decodeFrame(from: buf))
    }

    func testFrameDecode_unknownType_throws() {
        // 0x33 isn't a valid MessageType
        let buf = Data([0x33, 0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try PodSimulatorBridge.decodeFrame(from: buf))
    }

    func testSpawnAndConnect_returnsConnectAck() throws {
        // Locate the binary via the test bundle
        let bundle = Bundle(for: PodSimulatorBridgeTests.self)
        let binaryURL = bundle.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("pod-sim")
        XCTAssertTrue(FileManager.default.fileExists(atPath: binaryURL.path),
                      "pod-sim binary not at \(binaryURL.path) -- check Run Script Phase")

        let bridge = try PodSimulatorBridge(binaryURL: binaryURL, freshState: true)
        defer { bridge.terminate() }

        try bridge.send(type: .connect, payload: Data())
        let response = try bridge.receive(timeout: 2.0)

        XCTAssertEqual(response.type, .connectAck)
        XCTAssertEqual(response.payload, Data())
    }
}
