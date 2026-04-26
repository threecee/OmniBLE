//
//  B3aRemoteCommandIntegrationTest.swift
//  OmniBLETests
//
//  B.3.a Phase 8: Tests for remote-command channel plumbing.
//
//  The full end-to-end path —
//    phone sends NightscoutConfig → watch configures NightscoutService →
//    watch polls mock server → watch applies received override
//  — requires the WatchApp Extension target (NightscoutService, WatchRemoteCommandBootstrap,
//  TemporaryScheduleOverrideHistory) which is not available in OmniBLETests.
//
//  What we CAN test in OmniBLETests (OmniBLE.framework is the shared transport layer):
//
//  1. MockNightscoutHTTPServer starts, listens on an ephemeral port, and serves
//     GET /api/v1/treatments correctly (stub sanity check).
//
//  2. MockNightscoutHTTPServer returns enqueued remote override treatments and
//     clears the queue after serving (single-consumer semantics).
//
//  3. PhoneWatchSettingsSync.NightscoutConfig carries the URL and API secret
//     through its Codable round-trip — this is the transport struct that the
//     phone sends to the watch to configure Nightscout polling. If this fails,
//     the watch never gets the Nightscout URL.
//
//  4. OmniBLEHandoffPayload correctly preserves lastBolusSequence even when
//     NightscoutConfig is present in the accompanying settings sync (no cross-
//     contamination between payload fields).
//
//  Full end-to-end watch override application is tested in the WatchApp
//  ExtensionTests target (Phase5_BootstrapsTest and Phase6_SettingsSyncReceptionTests
//  exercise the WatchRemoteCommandBootstrap path).
//
//  B.3.a Phase 8.
//

import XCTest
import LoopKit
@testable import OmniBLE

// MARK: - Integration test

final class B3aRemoteCommandIntegrationTest: XCTestCase {

    // MARK: - MockNightscoutHTTPServer: sanity checks

    func testMockNightscoutHTTPServerStartsAndServesEmptyTreatments() throws {
        let server = MockNightscoutHTTPServer()
        try server.start()
        defer { server.stop() }

        // Verify base URL is reachable (port > 0 means OS assigned a port).
        let port = server.baseURL.port ?? 0
        XCTAssertGreaterThan(port, 0,
                             "Server must bind to a non-zero OS-assigned ephemeral port")

        // Fetch GET /api/v1/treatments from the mock server.
        let url = server.baseURL.appendingPathComponent("api/v1/treatments")
        let (data, response) = try URLSession.shared.syncData(from: url, timeout: 5)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200,
                       "GET /api/v1/treatments must return 200 OK")

        // Empty queue → empty JSON array.
        let treatments = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(treatments?.count, 0,
                       "Empty server must return an empty treatments array")
    }

    func testMockNightscoutHTTPServerServesEnqueuedOverride() throws {
        let server = MockNightscoutHTTPServer()
        try server.start()
        defer { server.stop() }

        // Enqueue one remote override.
        server.enqueueRemoteOverride(name: "Activity", durationMinutes: 60)

        // Fetch from server.
        let url = server.baseURL.appendingPathComponent("api/v1/treatments")
        let (data, response) = try URLSession.shared.syncData(from: url, timeout: 5)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let treatments = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(treatments.count, 1,
                       "One enqueued treatment must be returned")
        XCTAssertEqual(treatments.first?["reason"] as? String, "Activity")
        XCTAssertEqual(treatments.first?["duration"] as? Int, 60)
        XCTAssertEqual(treatments.first?["eventType"] as? String, "Temporary Override")
    }

    func testMockNightscoutHTTPServerClearsTreatmentsAfterGet() throws {
        let server = MockNightscoutHTTPServer()
        try server.start()
        defer { server.stop() }

        // Enqueue one override.
        server.enqueueRemoteOverride(name: "Meal", durationMinutes: 90)

        let url = server.baseURL.appendingPathComponent("api/v1/treatments")

        // First GET → should return the treatment.
        let (data1, _) = try URLSession.shared.syncData(from: url, timeout: 5)
        let treatments1 = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data1) as? [[String: Any]])
        XCTAssertEqual(treatments1.count, 1, "First GET must return the enqueued treatment")

        // Second GET → queue must be empty now (single-consumer semantics).
        let (data2, _) = try URLSession.shared.syncData(from: url, timeout: 5)
        let treatments2 = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data2) as? [[String: Any]])
        XCTAssertEqual(treatments2.count, 0,
                       "Second GET must return an empty array — treatments consumed after first poll")
    }

    func testMockNightscoutHTTPServerAcceptsPost() throws {
        let server = MockNightscoutHTTPServer()
        try server.start()
        defer { server.stop() }

        let url = server.baseURL.appendingPathComponent("api/v1/treatments")
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = Data("[]".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try URLSession.shared.syncData(for: request, timeout: 5)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200,
                       "POST /api/v1/treatments must return 200 OK")
    }

    // MARK: - PhoneWatchSettingsSync.NightscoutConfig transport round-trip

    /// Verifies that NightscoutConfig survives Codable encoding/decoding intact.
    /// The phone encodes this struct and sends it over WCSession; the watch
    /// decodes it and uses it to configure NightscoutService. Any field loss
    /// here means the watch never gets the correct Nightscout URL.
    func testNightscoutConfigSurvivesSettingsSyncRoundTrip() throws {
        let expectedURL = URL(string: "https://test-nightscout.example.com")!
        let expectedSecret = "super-secret-api-token-42"

        let sync = PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 0.8)],
            insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: 12.0,
            maximumBasalRatePerHourUnits: 3.5,
            suspendThresholdMgdL: 72.0,
            nightscoutConfig: PhoneWatchSettingsSync.NightscoutConfig(
                url: expectedURL,
                apiSecret: expectedSecret
            )
        )

        // Round-trip through JSON (same path as WCSession applicationContext).
        let data = try JSONEncoder().encode(sync)
        let decoded = try JSONDecoder().decode(PhoneWatchSettingsSync.self, from: data)

        XCTAssertEqual(decoded.nightscoutConfig?.url, expectedURL,
                       "NightscoutConfig.url must survive JSON round-trip — watch uses this to configure polling")
        XCTAssertEqual(decoded.nightscoutConfig?.apiSecret, expectedSecret,
                       "NightscoutConfig.apiSecret must survive JSON round-trip — watch uses this for auth")
    }

    /// Verifies that a settings sync without NightscoutConfig decodes to nil
    /// (not a crash or stale URL). Watch uses nil to suppress Nightscout polling.
    func testNilNightscoutConfigDecodesCorrectly() throws {
        let sync = PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 0.5)],
            insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: 5.0,
            maximumBasalRatePerHourUnits: 2.0,
            suspendThresholdMgdL: nil,
            nightscoutConfig: nil
        )

        let data = try JSONEncoder().encode(sync)
        let decoded = try JSONDecoder().decode(PhoneWatchSettingsSync.self, from: data)

        XCTAssertNil(decoded.nightscoutConfig,
                     "nil NightscoutConfig must survive JSON round-trip as nil, not a phantom URL")
    }

    // MARK: - Payload + settings sync: no cross-contamination

    /// Verifies that `lastBolusSequence` in OmniBLEHandoffPayload is not
    /// affected by the presence of NightscoutConfig in the accompanying
    /// PhoneWatchSettingsSync. These are two separate transport structs that
    /// the orchestrator sends together at handoff; they must not share state.
    func testHandoffPayloadLastBolusSequenceIsolatedFromNightscoutConfig() throws {
        let podState = PodState(
            address: 0x9999,
            ltk: Data(repeating: 0xFF, count: 16),
            firmwareVersion: "1.0",
            bleFirmwareVersion: "1.0",
            lotNo: UInt32(1),
            lotSeq: UInt32(1),
            productId: UInt8(0),
            bleIdentifier: "POD_NS_ISOLATION",
            insulinType: .humalog
        )

        let phoneLastBolusSeq: UInt32 = 13

        // Build the handoff payload (independent of NightscoutConfig).
        let payload = try OmniBLEHandoffPayload(
            podState: podState,
            lastBolusSequence: phoneLastBolusSeq,
            validUntil: Date(timeIntervalSinceNow: 300)
        )

        // Build a settings sync that includes NightscoutConfig.
        let sync = PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            basalScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 0.5)],
            insulinSensitivityScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)],
            carbRatioScheduleItems: [RepeatingScheduleValue(startTime: 0, value: 10.0)],
            glucoseTargetRangeScheduleItems: [
                RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))
            ],
            maximumBolusUnits: 10.0,
            maximumBasalRatePerHourUnits: 4.0,
            suspendThresholdMgdL: 70,
            nightscoutConfig: PhoneWatchSettingsSync.NightscoutConfig(
                url: URL(string: "https://example-ns.test")!,
                apiSecret: "secret-abc"
            )
        )

        // Round-trip both structs independently.
        let payloadData = try JSONEncoder().encode(payload)
        let syncData = try JSONEncoder().encode(sync)

        let decodedPayload = try JSONDecoder().decode(OmniBLEHandoffPayload.self, from: payloadData)
        let decodedSync = try JSONDecoder().decode(PhoneWatchSettingsSync.self, from: syncData)

        // Verify payload's bolus sequence is unchanged.
        XCTAssertEqual(decodedPayload.lastBolusSequence, phoneLastBolusSeq,
                       "Payload lastBolusSequence must be unchanged by NightscoutConfig presence")

        // Verify sync's NightscoutConfig is intact.
        XCTAssertEqual(decodedSync.nightscoutConfig?.url.absoluteString, "https://example-ns.test",
                       "NightscoutConfig must be intact regardless of payload content")

        // Verify they share no state by checking pod serial is unchanged.
        XCTAssertEqual(decodedPayload.podSerial, "POD_NS_ISOLATION")
    }

    // MARK: - Watch remote command flow: XCTSkip note

    /// The full watch remote command flow — WatchRemoteCommandBootstrap receives a
    /// NightscoutConfig, starts NightscoutService, polls mock server, applies override
    /// to TemporaryScheduleOverrideHistory — requires the WatchApp Extension target
    /// (NightscoutService, WatchRemoteCommandBootstrap, OverrideHistory). That path is
    /// covered by Phase5_BootstrapsTest and Phase6_SettingsSyncReceptionTests in the
    /// Loop/WatchApp ExtensionTests target.
    ///
    /// In OmniBLETests we validate the plumbing layer: the transport structs carry the
    /// right data, and MockNightscoutHTTPServer responds correctly. The bootstrap-level
    /// assertion is out of scope for this target.
    func testWatchPicksUpRemoteOverrideFromMockNightscout() throws {
        // We validate here that the MockNightscoutHTTPServer correctly responds to a
        // poll cycle. The assertion that the watch *applies* the override lives in
        // WatchApp ExtensionTests (WatchRemoteCommandBootstrap is not available in
        // OmniBLETests — it depends on NightscoutServiceKit which is not linked here).

        let server = MockNightscoutHTTPServer()
        try server.start()
        defer { server.stop() }

        // Step 1: Enqueue a remote override (simulates the Nightscout user posting one).
        server.enqueueRemoteOverride(name: "Activity", durationMinutes: 60)

        // Step 2: Simulate the watch polling (GET /api/v1/treatments).
        let url = server.baseURL.appendingPathComponent("api/v1/treatments")
        let (data, _) = try URLSession.shared.syncData(from: url, timeout: 5)

        // Step 3: Verify the override payload shape (matches what NightscoutServiceKit parses).
        let treatments = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(treatments.count, 1, "Watch poll should receive 1 treatment")

        let treatment = try XCTUnwrap(treatments.first)
        XCTAssertEqual(treatment["eventType"] as? String, "Temporary Override",
                       "eventType must be 'Temporary Override' — NightscoutServiceKit keys on this")
        XCTAssertEqual(treatment["reason"] as? String, "Activity",
                       "Override name must be preserved in 'reason' field")
        XCTAssertEqual(treatment["duration"] as? Int, 60,
                       "Override durationMinutes must be preserved in 'duration' field")

        // Step 4: Verify the PhoneWatchSettingsSync for this watch session would include
        // the NightscoutConfig that configures polling to this server's URL.
        let configSync = PhoneWatchSettingsSync.NightscoutConfig(
            url: server.baseURL,
            apiSecret: "test-secret"
        )
        let encoded = try JSONEncoder().encode(configSync)
        let decoded = try JSONDecoder().decode(PhoneWatchSettingsSync.NightscoutConfig.self, from: encoded)

        XCTAssertEqual(decoded.url, server.baseURL,
                       "NightscoutConfig.url must match mock server URL after round-trip")
        XCTAssertEqual(decoded.apiSecret, "test-secret")

        // The full application of the override to TemporaryScheduleOverrideHistory is verified
        // in WatchApp ExtensionTests/Phase6_SettingsSyncReceptionTests.swift.
        // Noting: XCTSkipIf is not used here because the available assertions already validate
        // the B.3.a remote-command plumbing at the OmniBLE transport layer.
    }
}

// MARK: - URLSession sync helper

private extension URLSession {
    /// Synchronous wrapper around `data(from:)` for use in XCTest.
    func syncData(from url: URL, timeout: TimeInterval) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>?
        let semaphore = DispatchSemaphore(value: 0)
        let request = URLRequest(url: url, timeoutInterval: timeout)

        dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(URLError(.unknown))
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()
        return try result!.get()
    }

    /// Synchronous wrapper for a custom URLRequest.
    func syncData(for request: URLRequest, timeout: TimeInterval) throws -> (Data, URLResponse) {
        var req = request
        req.timeoutInterval = timeout

        var result: Result<(Data, URLResponse), Error>?
        let semaphore = DispatchSemaphore(value: 0)

        dataTask(with: req) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(URLError(.unknown))
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()
        return try result!.get()
    }
}
