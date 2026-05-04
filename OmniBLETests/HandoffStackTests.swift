//
//  HandoffStackTests.swift
//  OmniBLETests
//
//  B.10 Phase 8: tests for HandoffStack.assemble(role:) factory.
//  Verifies the factory builds a complete stack on both roles, that
//  every component is wired non-nil, and that the factory is reentrant
//  (multiple `assemble` invocations return distinct instances — we do
//  NOT want a hidden singleton inside the factory).
//

import XCTest
@testable import OmniBLE

@MainActor
final class HandoffStackTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "com.LoopKit.OmniBLE.HandoffStackTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    func test_assemble_phone_buildsStack() {
        let stack = HandoffStack.assemble(
            role: .phone,
            appGroupDefaults: isolatedDefaults()
        )
        XCTAssertNotNil(stack.transport)
        XCTAssertNotNil(stack.coordinator)
        XCTAssertNotNil(stack.stateMachine)
        XCTAssertNotNil(stack.policyEngine)
        XCTAssertNotNil(stack.shadowScheduler)
        XCTAssertNotNil(stack.orchestrator)
        // State machine starts in phoneDriver (no persisted state in the
        // isolated defaults).
        XCTAssertEqual(stack.stateMachine.state, .phoneDriver)
    }

    func test_assemble_watch_buildsStack() {
        var settingsSyncCallCount = 0
        var snapshotCallCount = 0
        let stack = HandoffStack.assemble(
            role: .watch,
            appGroupDefaults: isolatedDefaults(),
            onSettingsSyncReceived: { _ in settingsSyncCallCount += 1 },
            onSnapshotReceived: { _ in snapshotCallCount += 1 }
        )
        XCTAssertNotNil(stack.transport)
        XCTAssertNotNil(stack.coordinator)
        XCTAssertNotNil(stack.stateMachine)
        XCTAssertNotNil(stack.policyEngine)
        XCTAssertNotNil(stack.shadowScheduler)
        XCTAssertNotNil(stack.orchestrator)
        // The closure parameters are stored on the coordinator; we don't
        // exercise them here (Pair C tests cover that). We only assert
        // the stack assembles cleanly with watch-only injection.
        XCTAssertEqual(settingsSyncCallCount, 0)
        XCTAssertEqual(snapshotCallCount, 0)
    }

    func test_assemble_isReentrant_returnsDistinctInstances() {
        let s1 = HandoffStack.assemble(role: .phone, appGroupDefaults: isolatedDefaults())
        let s2 = HandoffStack.assemble(role: .phone, appGroupDefaults: isolatedDefaults())
        // Each invocation must produce a fresh stack — the factory must
        // not cache singletons internally. (`HandoffOrchestrator.shared`
        // is the caller's responsibility, not the factory's.)
        XCTAssertFalse(s1.orchestrator === s2.orchestrator)
        XCTAssertFalse(s1.transport === s2.transport)
        XCTAssertFalse(s1.coordinator === s2.coordinator)
        XCTAssertFalse(s1.stateMachine === s2.stateMachine)
        XCTAssertFalse(s1.policyEngine === s2.policyEngine)
        XCTAssertFalse(s1.shadowScheduler === s2.shadowScheduler)
    }
}
