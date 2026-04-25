//
//  HandoffSettingsTests.swift
//  OmniBLETests
//

import XCTest
@testable import OmniBLE

final class HandoffSettingsTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suiteName = "test.handoff-\(UUID())"
        UserDefaults().removePersistentDomain(forName: suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    func testDefaultModeIsAutomatic() {
        // B.2.e Phase 7 lifted the BETA gate — defaultMode flipped from
        // .manual to .automatic. Existing users keep their setting; only
        // new installs default to .automatic.
        let settings = HandoffSettings()
        XCTAssertEqual(settings.mode, .automatic)
    }

    func testRoundTripsThroughDefaults() throws {
        let defaults = freshDefaults()
        let original = HandoffSettings(mode: .manual)   // explicit non-default value
        try original.save(to: defaults)
        let loaded = HandoffSettings.load(from: defaults)
        XCTAssertEqual(loaded.mode, .manual)
    }

    func testLoadFromEmptyDefaultsReturnsDefault() {
        let loaded = HandoffSettings.load(from: freshDefaults())
        XCTAssertEqual(loaded.mode, .automatic)
    }
}
