//
//  HandoffOrchestratorTests.swift
//  OmniBLETests
//
//  B.11.1 Phase 5: tests for the role-gated proxyUpload(for:) method on
//  HandoffOrchestrator + quiesce-on-handoff side effects fired during
//  state transitions in/out of the local-driver role.
//
//  Driver-only-writes invariant + quiesce semantics are the load-bearing
//  pediatric-safety contracts of B.11.1 — these tests guard them.
//

import XCTest
@testable import OmniBLE

@MainActor
final class HandoffOrchestratorTests: XCTestCase {

    // MARK: - Mock RemoteCareUploader

    /// Records every upload(...) / quiesce() / resume() call. Used to
    /// verify role-gating behavior end-to-end through the orchestrator.
    final class MockRemoteCareUploader: RemoteCareUploader {
        var uploadCalls: [RemoteCareUploadType] = []
        var quiesceCount: Int = 0
        var resumeCount: Int = 0
        private(set) var isQuiesced: Bool = false

        func upload(for type: RemoteCareUploadType) {
            guard !isQuiesced else { return }
            uploadCalls.append(type)
        }
        func quiesce() {
            quiesceCount += 1
            isQuiesced = true
        }
        func resume() {
            resumeCount += 1
            isQuiesced = false
        }
    }

    // MARK: - Fixtures

    /// Build a fresh orchestrator using HandoffStack.assemble with isolated
    /// per-test UserDefaults (so persisted state never leaks between tests).
    private func makeOrchestrator(role: HandoffRole) -> HandoffOrchestrator {
        let suiteName = "HandoffOrchestratorTests-\(role.rawValue)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let stack = HandoffStack.assemble(role: role, appGroupDefaults: defaults)
        return stack.orchestrator
    }

    // MARK: - Driver gate (proxyUpload)

    func testDriverUploadProxyForwardsWhenRoleIsCurrentDriver() {
        // Phone-role orchestrator, state .phoneDriver (the seed state).
        let mock = MockRemoteCareUploader()
        let orch = makeOrchestrator(role: .phone)
        orch.remoteCareUploader = mock

        XCTAssertEqual(orch.handoffState, .phoneDriver)
        XCTAssertTrue(orch.isCurrentDriver, "Phone in .phoneDriver must be current driver")

        orch.proxyUpload(for: .glucose)
        orch.proxyUpload(for: .dosingDecision)

        XCTAssertEqual(mock.uploadCalls, [.glucose, .dosingDecision])
    }

    func testPassengerUploadProxyShortCircuitsAndLogsWarning() {
        // Watch-role orchestrator, state .phoneDriver (so watch is passenger).
        let mock = MockRemoteCareUploader()
        let orch = makeOrchestrator(role: .watch)
        orch.remoteCareUploader = mock

        XCTAssertEqual(orch.handoffState, .phoneDriver)
        XCTAssertFalse(orch.isCurrentDriver, "Watch in .phoneDriver must NOT be current driver")

        orch.proxyUpload(for: .glucose)
        orch.proxyUpload(for: .dose)

        XCTAssertEqual(mock.uploadCalls, [],
                       "Passenger calls must not reach the underlying uploader")
        // The warning is a debug-log signal; we don't assert on log
        // contents (test would be brittle), but the empty uploadCalls is
        // the load-bearing assertion: passengers MUST NOT upload.
    }

    // MARK: - Quiesce/resume on role flip

    private func handoffPendingPhoneToWatch() -> HandoffState {
        .handoffPending(direction: .phoneToWatch,
                        transitionId: UUID(),
                        deadline: Date().addingTimeInterval(60))
    }

    func testQuiesceOnRoleFlipOutOfDriver() {
        // Phone-role orchestrator transitioning .phoneDriver -> .handoffPending.
        // Phone is leaving driver role; its uploader must be quiesced.
        let mock = MockRemoteCareUploader()
        let orch = makeOrchestrator(role: .phone)
        orch.remoteCareUploader = mock

        XCTAssertEqual(mock.quiesceCount, 0)
        XCTAssertTrue(orch.isCurrentDriver)

        // Drive a state transition that flips phone out of driver.
        orch.execute([.notifyUI(state: handoffPendingPhoneToWatch())])

        XCTAssertEqual(mock.quiesceCount, 1, "Quiesce must fire on flip-out-of-driver")
        XCTAssertEqual(mock.resumeCount, 0)
        XCTAssertFalse(orch.isCurrentDriver, "Handoff-pending must mean no current driver")
    }

    func testResumeOnRoleFlipBackToDriver() {
        // Phone: .phoneDriver -> .handoffPending (quiesce) -> .phoneDriver (resume).
        let mock = MockRemoteCareUploader()
        let orch = makeOrchestrator(role: .phone)
        orch.remoteCareUploader = mock

        orch.execute([.notifyUI(state: handoffPendingPhoneToWatch())])
        XCTAssertEqual(mock.quiesceCount, 1)
        XCTAssertEqual(mock.resumeCount, 0)

        // Roll back to phoneDriver.
        orch.execute([.notifyUI(state: .phoneDriver)])
        XCTAssertEqual(mock.resumeCount, 1, "Resume must fire on flip-back-to-driver")
    }

    // MARK: - End-to-end dedup (per-iteration no double-write)

    /// End-to-end dedup test: phone-role and watch-role orchestrators
    /// driven through the same logical timeline; assert that across the
    /// transition window, no iteration is uploaded by both devices.
    func testDedupNoDoubleWriteAcrossPhoneToWatchHandoff() {
        let phoneMock = MockRemoteCareUploader()
        let watchMock = MockRemoteCareUploader()
        let phoneOrch = makeOrchestrator(role: .phone)
        let watchOrch = makeOrchestrator(role: .watch)
        phoneOrch.remoteCareUploader = phoneMock
        watchOrch.remoteCareUploader = watchMock

        // Iteration N: phone is driver. Phone uploads, watch is silent.
        XCTAssertEqual(phoneOrch.handoffState, .phoneDriver)
        XCTAssertEqual(watchOrch.handoffState, .phoneDriver)
        phoneOrch.proxyUpload(for: .glucose)
        watchOrch.proxyUpload(for: .glucose)
        XCTAssertEqual(phoneMock.uploadCalls.count, 1)
        XCTAssertEqual(watchMock.uploadCalls.count, 0)

        // Iteration N+1 (handoff initiated): both orchestrators move to
        // handoffPending(phoneToWatch). Phone quiesces; watch is still
        // passenger.
        let pendingState = handoffPendingPhoneToWatch()
        phoneOrch.execute([.notifyUI(state: pendingState)])
        watchOrch.execute([.notifyUI(state: pendingState)])
        phoneOrch.proxyUpload(for: .glucose)
        watchOrch.proxyUpload(for: .glucose)
        // Phone is quiesced AND no longer driver — both reasons block.
        XCTAssertEqual(phoneMock.uploadCalls.count, 1, "Phone must not upload after quiesce")
        XCTAssertEqual(watchMock.uploadCalls.count, 0, "Watch is still passenger")

        // Iteration N+2: state advances to .watchDriver. Watch resumes
        // (was passenger; now watch-driver). Phone stays passenger.
        phoneOrch.execute([.notifyUI(state: .watchDriver)])
        watchOrch.execute([.notifyUI(state: .watchDriver)])
        phoneOrch.proxyUpload(for: .glucose)
        watchOrch.proxyUpload(for: .glucose)
        XCTAssertEqual(phoneMock.uploadCalls.count, 1, "Phone is now passenger; no new uploads")
        XCTAssertEqual(watchMock.uploadCalls.count, 1, "Watch is now driver; uploads")

        // Verify no double-write across the 3 iterations: 1 phone + 1
        // watch + 0 overlap = 2 total uploads.
        let totalUploads = phoneMock.uploadCalls.count + watchMock.uploadCalls.count
        XCTAssertEqual(totalUploads, 2,
            "Each iteration's data was uploaded by exactly one device — no dedup violations")
    }
}
