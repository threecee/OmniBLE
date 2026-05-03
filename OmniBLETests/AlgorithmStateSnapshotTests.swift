import XCTest
@testable import OmniBLE

final class PumpStatusSnapshotTests: XCTestCase {
    func test_roundTrip_preservesAllFields() throws {
        let original = PumpStatusSnapshot(
            reservoirUnitsRemaining: 137.5,
            lastBasalRateUnitsPerHour: 0.85,
            isSuspended: false,
            lastReadingDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PumpStatusSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
