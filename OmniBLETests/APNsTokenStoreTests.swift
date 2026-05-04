//
//  APNsTokenStoreTests.swift
//  OmniBLETests
//
//  B.11.0 round-trip + multi-role tests for the App-Group-backed token
//  persistence layer.
//

import XCTest
@testable import OmniBLE

final class APNsTokenStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: APNsTokenStore!

    override func setUp() {
        super.setUp()
        // Use an isolated suite so tests don't pollute the shared App Group.
        let suite = "APNsTokenStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = APNsTokenStore(defaults: defaults)
    }

    override func tearDown() {
        store.clear(role: .phone)
        store.clear(role: .watch)
        super.tearDown()
    }

    func testSaveAndLoadPhoneTokenRoundTrip() {
        let pub = APNsTokenPublication(
            protocolVersion: 7,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            role: .phone,
            token: Data([0x01, 0x02, 0x03]),
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + 60 * 60 * 24 * 30)
        )
        store.save(pub)
        XCTAssertEqual(store.load(role: .phone), pub)
        XCTAssertNil(store.load(role: .watch),
                     "saving phone slot must not populate watch slot")
    }

    func testSaveAndLoadWatchTokenRoundTrip() {
        let pub = APNsTokenPublication(
            protocolVersion: 7,
            sentAt: Date(timeIntervalSince1970: 1_700_000_100),
            role: .watch,
            token: Data([0xa1, 0xb2, 0xc3, 0xd4]),
            expiresAt: Date(timeIntervalSince1970: 1_700_000_100 + 60 * 60 * 24 * 30)
        )
        store.save(pub)
        XCTAssertEqual(store.load(role: .watch), pub)
        XCTAssertNil(store.load(role: .phone),
                     "saving watch slot must not populate phone slot")
    }

    func testReSaveOverwrites() {
        let first = APNsTokenPublication(
            protocolVersion: 7, sentAt: Date(timeIntervalSince1970: 1),
            role: .phone, token: Data([0xff]),
            expiresAt: Date(timeIntervalSince1970: 100))
        let second = APNsTokenPublication(
            protocolVersion: 7, sentAt: Date(timeIntervalSince1970: 2),
            role: .phone, token: Data([0xee]),
            expiresAt: Date(timeIntervalSince1970: 200))
        store.save(first)
        store.save(second)
        XCTAssertEqual(store.load(role: .phone), second)
    }

    func testClearRemovesSlot() {
        let pub = APNsTokenPublication(
            protocolVersion: 7, sentAt: Date(),
            role: .phone, token: Data([0x42]),
            expiresAt: Date().addingTimeInterval(60))
        store.save(pub)
        store.clear(role: .phone)
        XCTAssertNil(store.load(role: .phone))
    }
}
