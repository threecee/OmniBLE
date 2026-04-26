//
//  MockNightscoutHTTPServer.swift
//  OmniBLETests
//
//  Tiny embedded HTTP server for testing remote-command flow on watch.
//  Implements only the Nightscout endpoints the watch's NightscoutService
//  polls: GET /api/v1/treatments and POST /api/v1/treatments.
//
//  Uses Foundation's Network framework — no third-party deps.
//
//  B.3.a Phase 8.
//

import Foundation
import Network

/// A minimal Nightscout HTTP stub that runs on an OS-assigned ephemeral port.
/// Suitable for testing that the watch-side remote command plumbing can reach
/// a Nightscout instance and parse treatment responses.
///
/// Usage:
/// ```swift
/// let server = MockNightscoutHTTPServer()
/// try server.start()
/// defer { server.stop() }
/// // use server.baseURL as the Nightscout base URL in test helpers
/// server.enqueueRemoteOverride(name: "Activity", durationMinutes: 60)
/// ```
final class MockNightscoutHTTPServer {

    // MARK: - State

    private var listener: NWListener?
    private var assignedPort: UInt16 = 0
    private var pendingTreatments: [[String: Any]] = []
    private let queue = DispatchQueue(label: "MockNightscoutHTTPServer", qos: .utility)
    private let stateLock = NSLock()

    // MARK: - Public API

    /// The HTTP base URL of this server. Only valid after `start()` has been called.
    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(assignedPort)")!
    }

    /// Start listening on an OS-assigned ephemeral port.
    /// After this returns, `baseURL` reflects the real bound port.
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Port 0 → OS assigns a free ephemeral port.
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 0)!)

        let portReady = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Capture the actual assigned port.
                if let port = self?.listener?.port?.rawValue {
                    self?.assignedPort = port
                }
                portReady.signal()
            case .failed(let error):
                // Unblock the semaphore even on failure so start() doesn't hang.
                _ = error
                portReady.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        self.listener = listener
        listener.start(queue: queue)

        // Wait (max 5 s) for the port to be bound.
        let result = portReady.wait(timeout: .now() + 5)
        if result == .timedOut {
            listener.cancel()
            throw MockNightscoutError.portBindTimeout
        }
    }

    /// Stop the server and release the port.
    func stop() {
        listener?.cancel()
        listener = nil
        stateLock.lock()
        pendingTreatments.removeAll()
        stateLock.unlock()
    }

    // MARK: - Treatment queue

    /// Enqueue a Nightscout "Temporary Override" treatment that will be returned
    /// by the next `GET /api/v1/treatments` call, then cleared.
    func enqueueRemoteOverride(name: String, durationMinutes: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        pendingTreatments.append([
            "eventType": "Temporary Override",
            "reason": name,
            "duration": durationMinutes,
            "created_at": ISO8601DateFormatter().string(from: Date())
        ])
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1,
                          maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            let responseBytes = self.response(for: request)
            connection.send(content: responseBytes,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(for request: String) -> Data {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""

        if firstLine.hasPrefix("GET /api/v1/treatments") {
            stateLock.lock()
            let treatments = pendingTreatments
            pendingTreatments.removeAll()
            stateLock.unlock()

            let body: Data
            if let json = try? JSONSerialization.data(withJSONObject: treatments) {
                body = json
            } else {
                body = Data("[]".utf8)
            }
            return httpResponse(status: "200 OK",
                                contentType: "application/json",
                                body: body)
        } else if firstLine.hasPrefix("POST /api/v1/treatments") {
            return httpResponse(status: "200 OK",
                                contentType: "application/json",
                                body: Data("[]".utf8))
        } else {
            return httpResponse(status: "404 Not Found",
                                contentType: "text/plain",
                                body: Data())
        }
    }

    private func httpResponse(status: String, contentType: String, body: Data) -> Data {
        let header = "HTTP/1.1 \(status)\r\n" +
                     "Content-Type: \(contentType)\r\n" +
                     "Content-Length: \(body.count)\r\n" +
                     "Connection: close\r\n\r\n"
        var result = Data(header.utf8)
        result.append(body)
        return result
    }
}

// MARK: - Errors

enum MockNightscoutError: Error {
    case portBindTimeout
}
