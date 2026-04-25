//
//  PodSimulatorBridge.swift
//  OmniBLETests
//
//  Spawns and owns the pod-sim Go subprocess. Encodes/decodes the
//  tagged-binary envelope. Single-threaded; one PodSimulatorBridge per
//  test method (per-test fresh subprocess; see PodSimulatorTestCase in Phase 4).
//
//  Wire format (mirror of pkg/bridge/framing.go):
//    [1 byte: type][4 bytes: length, big-endian][N bytes: payload]
//
//  Uses POSIX APIs (posix_spawn, pipe, read, write) rather than Foundation.Process
//  so the code compiles against the iOS SDK (used when running tests in iOS Simulator).
//

import Foundation

enum PodSimulatorBridgeError: Error, CustomStringConvertible {
    case binaryNotFound(URL)
    case truncatedHeader
    case truncatedPayload(expected: Int, got: Int)
    case unknownBridgeMessageType(UInt8)
    case timeout
    case subprocessExited(Int32, stderrTail: String)
    case writeFailed(String)
    case spawnFailed(Int32)

    var description: String {
        switch self {
        case .binaryNotFound(let url): return "pod-sim binary not found at \(url.path)"
        case .truncatedHeader: return "truncated frame header (need 5 bytes)"
        case .truncatedPayload(let expected, let got): return "truncated payload: expected \(expected), got \(got)"
        case .unknownBridgeMessageType(let raw): return "unknown message type: 0x\(String(raw, radix: 16))"
        case .timeout: return "subprocess did not respond within timeout"
        case .subprocessExited(let code, let tail): return "subprocess exited with code \(code); stderr: \(tail)"
        case .writeFailed(let why): return "write to subprocess failed: \(why)"
        case .spawnFailed(let errno): return "posix_spawn failed with errno \(errno)"
        }
    }
}

final class PodSimulatorBridge {

    private let pid: pid_t

    /// Write end of the child's stdin pipe (parent writes here).
    private let stdinWriteFD: Int32
    /// Read end of the child's stdout pipe (parent reads here).
    private let stdoutReadFD: Int32
    /// Read end of the child's stderr pipe (parent reads here).
    private let stderrReadFD: Int32

    /// Buffer for partial frames received from stdout.
    private var rxBuffer = Data()

    /// Captured stderr (for diagnostics on subprocess crash).
    private var stderrBuffer = Data()
    private let stderrLock = NSLock()

    /// Background thread draining stderr.
    private var stderrThread: Thread?
    private var terminated = false

    init(binaryURL: URL, freshState: Bool, autoDisconnect: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw PodSimulatorBridgeError.binaryNotFound(binaryURL)
        }

        // Build argument list
        var args: [String] = ["-q"]
        if freshState { args.append("-fresh") }
        if !autoDisconnect { args.append("-no-auto-disconnect") }

        // Create pipes: [read_end, write_end]
        var stdinPipe = [Int32](repeating: 0, count: 2)
        var stdoutPipe = [Int32](repeating: 0, count: 2)
        var stderrPipe = [Int32](repeating: 0, count: 2)
        pipe(&stdinPipe)
        pipe(&stdoutPipe)
        pipe(&stderrPipe)

        // Configure file actions: wire child's stdio to our pipes
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        // Child stdin = read end of stdinPipe
        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO)
        // Child stdout = write end of stdoutPipe
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        // Child stderr = write end of stderrPipe
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        // Close parent ends in child
        posix_spawn_file_actions_addclose(&fileActions, stdinPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])

        let binaryPath = binaryURL.path
        var argv: [UnsafeMutablePointer<Int8>?] = ([binaryPath] + args).map { strdup($0) }
        argv.append(nil)
        defer { argv.compactMap { $0 }.forEach { free($0) } }

        var spawnedPid: pid_t = 0
        let spawnResult = posix_spawn(&spawnedPid, binaryPath, &fileActions, nil, &argv, nil)
        posix_spawn_file_actions_destroy(&fileActions)

        if spawnResult != 0 {
            // Close all pipe ends on failure
            close(stdinPipe[0]); close(stdinPipe[1])
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            throw PodSimulatorBridgeError.spawnFailed(spawnResult)
        }

        // Close child ends in parent
        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])

        self.pid = spawnedPid
        self.stdinWriteFD = stdinPipe[1]
        self.stdoutReadFD = stdoutPipe[0]
        self.stderrReadFD = stderrPipe[0]

        // Drain stderr on a background thread so the pipe never fills and blocks the child
        let thread = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(stderrPipe[0], &buf, buf.count)
                if n <= 0 { break }
                let chunk = Data(buf[0..<n])
                self.stderrLock.lock()
                self.stderrBuffer.append(chunk)
                self.stderrLock.unlock()
            }
        }
        thread.name = "PodSimulatorBridge.stderr"
        thread.start()
        self.stderrThread = thread
    }

    /// Send a frame. Returns when bytes are written to the pipe.
    func send(type: BridgeMessageType, payload: Data) throws {
        let frame = Self.encodeFrame(type: type, payload: payload)
        var written = 0
        try frame.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            while written < frame.count {
                let n = Darwin.write(stdinWriteFD, base.advanced(by: written), frame.count - written)
                if n < 0 {
                    throw PodSimulatorBridgeError.writeFailed("errno \(errno)")
                }
                written += n
            }
        }
    }

    /// Receive the next complete frame, blocking up to `timeout` seconds.
    /// Polls stdout non-blockingly; sleeps 5ms between polls.
    func receive(timeout: TimeInterval) throws -> (type: BridgeMessageType, payload: Data) {
        let deadline = Date().addingTimeInterval(timeout)

        // Make stdout non-blocking
        let flags = fcntl(stdoutReadFD, F_GETFL, 0)
        _ = fcntl(stdoutReadFD, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(stdoutReadFD, F_SETFL, flags) }

        var buf = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            // Try to decode a complete frame from the buffer
            if let (type, payload, consumed) = tryDecodeFromBuffer() {
                rxBuffer.removeFirst(consumed)
                return (type, payload)
            }

            // Read more data (non-blocking)
            let n = Darwin.read(stdoutReadFD, &buf, buf.count)
            if n > 0 {
                rxBuffer.append(contentsOf: buf[0..<n])
                continue
            } else if n < 0 && errno == EAGAIN {
                // No data yet — check if child exited
                var status: Int32 = 0
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid {
                    let exitCode = (status >> 8) & 0xFF
                    let tail = stderrTail()
                    throw PodSimulatorBridgeError.subprocessExited(Int32(exitCode), stderrTail: tail)
                }
                Thread.sleep(forTimeInterval: 0.005)
                continue
            } else if n == 0 {
                // EOF — pipe closed
                let tail = stderrTail()
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
                let exitCode = (status >> 8) & 0xFF
                throw PodSimulatorBridgeError.subprocessExited(Int32(exitCode), stderrTail: tail)
            } else {
                // Actual read error
                throw PodSimulatorBridgeError.writeFailed("read errno \(errno)")
            }
        }
        throw PodSimulatorBridgeError.timeout
    }

    /// Drain the stderr buffer so far. Useful for diagnostics on test failure.
    func stderrTail(maxBytes: Int = 4096) -> String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        let bytes = stderrBuffer.suffix(maxBytes)
        return String(data: bytes, encoding: .utf8) ?? "<non-UTF-8 stderr>"
    }

    /// Terminate the subprocess. Call from XCTestCase tearDown.
    func terminate() {
        guard !terminated else { return }
        terminated = true

        // Close stdin so the binary sees EOF and can exit cleanly
        close(stdinWriteFD)

        // Give the child a brief chance for clean exit
        let deadline = Date().addingTimeInterval(0.5)
        var status: Int32 = 0
        while Date() < deadline {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        // SIGTERM if still running
        var r = waitpid(pid, &status, WNOHANG)
        if r != pid {
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.1)
            r = waitpid(pid, &status, WNOHANG)
        }

        // SIGKILL last resort
        if r != pid {
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }

        // Close remaining file descriptors
        close(stdoutReadFD)
        close(stderrReadFD)
    }

    private func tryDecodeFromBuffer() -> (BridgeMessageType, Data, Int)? {
        guard rxBuffer.count >= 5 else { return nil }
        let typeRaw = rxBuffer[rxBuffer.startIndex]
        guard let type = BridgeMessageType(rawValue: typeRaw) else { return nil }
        let lenStart = rxBuffer.startIndex + 1
        let length = UInt32(rxBuffer[lenStart]) << 24
                   | UInt32(rxBuffer[lenStart + 1]) << 16
                   | UInt32(rxBuffer[lenStart + 2]) << 8
                   | UInt32(rxBuffer[lenStart + 3])
        let totalLen = 5 + Int(length)
        guard rxBuffer.count >= totalLen else { return nil }
        let payloadStart = rxBuffer.startIndex + 5
        let payload = Data(rxBuffer[payloadStart..<(payloadStart + Int(length))])
        return (type, payload, totalLen)
    }

    // MARK: - Static framing helpers (for unit tests)

    static func encodeFrame(type: BridgeMessageType, payload: Data) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(type.rawValue)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    static func decodeFrame(from data: Data) throws -> (type: BridgeMessageType, payload: Data) {
        guard data.count >= 5 else { throw PodSimulatorBridgeError.truncatedHeader }
        let typeRaw = data[data.startIndex]
        guard let type = BridgeMessageType(rawValue: typeRaw) else {
            throw PodSimulatorBridgeError.unknownBridgeMessageType(typeRaw)
        }
        let lenStart = data.startIndex + 1
        let length = UInt32(data[lenStart]) << 24
                   | UInt32(data[lenStart + 1]) << 16
                   | UInt32(data[lenStart + 2]) << 8
                   | UInt32(data[lenStart + 3])
        let needed = 5 + Int(length)
        guard data.count >= needed else {
            throw PodSimulatorBridgeError.truncatedPayload(expected: needed, got: data.count)
        }
        let payloadStart = data.startIndex + 5
        let payload = Data(data[payloadStart..<(payloadStart + Int(length))])
        return (type, payload)
    }
}
