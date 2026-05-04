//
//  RemoteCareDedupE2ETests.swift
//  OmniBLETests
//
//  B.11.1 Phase 8: end-to-end dedup test. Drives both phone-role and
//  watch-role orchestrators through a simulated phone->watch handoff.
//  Asserts that across the transition window, no iteration's upload
//  is performed by both devices.
//

import XCTest
@testable import OmniBLE

@MainActor
final class RemoteCareDedupE2ETests: XCTestCase {

    final class RecordingUploader: RemoteCareUploader {
        struct Call: Equatable {
            let device: String
            let iteration: Int
            let type: RemoteCareUploadType
        }

        let device: String
        var calls: [Call] = []
        private(set) var isQuiesced: Bool = false
        private var iterationCounter: Int = 0

        init(device: String) { self.device = device }

        // Tests bump the iteration counter externally so we can label
        // simultaneous calls from phone+watch in the same logical tick.
        func setIteration(_ n: Int) { iterationCounter = n }

        func upload(for type: RemoteCareUploadType) {
            guard !isQuiesced else { return }
            calls.append(Call(device: device, iteration: iterationCounter, type: type))
        }
        func quiesce() { isQuiesced = true }
        func resume() { isQuiesced = false }
    }

    // MARK: - Fixture: per-test orchestrator with isolated UserDefaults

    private func makeOrchestrator(role: HandoffRole) -> HandoffOrchestrator {
        let suiteName = "RemoteCareDedupE2ETests-\(role.rawValue)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let stack = HandoffStack.assemble(role: role, appGroupDefaults: defaults)
        return stack.orchestrator
    }

    private func handoffPendingPhoneToWatch() -> HandoffState {
        .handoffPending(direction: .phoneToWatch,
                        transitionId: UUID(),
                        deadline: Date().addingTimeInterval(60),
                        tokenRendezvousPublished: false)
    }

    func testNoDoubleWriteAcrossPhoneToWatchHandoffWindow() {
        let phoneUploader = RecordingUploader(device: "phone")
        let watchUploader = RecordingUploader(device: "watch")
        let phoneOrch = makeOrchestrator(role: .phone)
        let watchOrch = makeOrchestrator(role: .watch)
        phoneOrch.remoteCareUploader = phoneUploader
        watchOrch.remoteCareUploader = watchUploader

        // Iteration 1: phone driver. Both orchestrators see .phoneDriver.
        phoneUploader.setIteration(1); watchUploader.setIteration(1)
        phoneOrch.proxyUpload(for: .glucose)
        watchOrch.proxyUpload(for: .glucose)

        // Iteration 2: handoffPending. Phone quiesces; both are passengers.
        let pending = handoffPendingPhoneToWatch()
        phoneOrch.execute([.notifyUI(state: pending)])
        watchOrch.execute([.notifyUI(state: pending)])
        phoneUploader.setIteration(2); watchUploader.setIteration(2)
        phoneOrch.proxyUpload(for: .glucose)
        watchOrch.proxyUpload(for: .glucose)

        // Iteration 3: watchDriver. Phone stays passenger; watch resumes
        // (its quiesce count was 0, so resume is a no-op semantically).
        phoneOrch.execute([.notifyUI(state: .watchDriver)])
        watchOrch.execute([.notifyUI(state: .watchDriver)])
        phoneUploader.setIteration(3); watchUploader.setIteration(3)
        phoneOrch.proxyUpload(for: .glucose)
        watchOrch.proxyUpload(for: .glucose)

        // Iteration 4: still watchDriver (steady state).
        phoneUploader.setIteration(4); watchUploader.setIteration(4)
        phoneOrch.proxyUpload(for: .glucose)
        watchOrch.proxyUpload(for: .glucose)

        // ASSERT: per-iteration dedup. For each iteration n, at most one
        // device's RecordingUploader has a Call with iteration == n.
        let allCalls = phoneUploader.calls + watchUploader.calls
        let byIteration = Dictionary(grouping: allCalls, by: { $0.iteration })
        for (iteration, calls) in byIteration {
            XCTAssertEqual(calls.count, 1,
                "Iteration \(iteration) had \(calls.count) uploads (expected 1): \(calls)")
        }

        // ASSERT: expected timeline.
        // - Iteration 1: phone uploads (driver).
        // - Iteration 2: nobody uploads (both passengers + phone quiesced).
        // - Iteration 3: watch uploads (driver).
        // - Iteration 4: watch uploads (driver).
        XCTAssertEqual(phoneUploader.calls.map { $0.iteration }, [1])
        XCTAssertEqual(watchUploader.calls.map { $0.iteration }, [3, 4])
    }
}
