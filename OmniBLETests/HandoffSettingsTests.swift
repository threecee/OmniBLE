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

    func testDefaultModeIsManual() {
        let settings = HandoffSettings()
        XCTAssertEqual(settings.mode, .manual)
    }

    func testRoundTripsThroughDefaults() throws {
        let defaults = freshDefaults()
        let original = HandoffSettings(mode: .automatic)
        try original.save(to: defaults)
        let loaded = HandoffSettings.load(from: defaults)
        XCTAssertEqual(loaded.mode, .automatic)
    }

    func testLoadFromEmptyDefaultsReturnsDefault() {
        let loaded = HandoffSettings.load(from: freshDefaults())
        XCTAssertEqual(loaded.mode, .manual)
    }
}
