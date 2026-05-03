import XCTest
import HealthKit
import LoopKit
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

final class AlgorithmStateSnapshotPayloadTests: XCTestCase {
    func test_roundTrip_preservesIdentifyingFields() throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AlgorithmStateSnapshot(
            snapshotID: id,
            createdAt: now,
            phoneIterationDate: now.addingTimeInterval(-3),
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: PumpStatusSnapshot(
                reservoirUnitsRemaining: 100,
                lastBasalRateUnitsPerHour: 0.5,
                isSuspended: false,
                lastReadingDate: now
            ),
            activeOverride: nil
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AlgorithmStateSnapshot.self, from: data)
        XCTAssertEqual(decoded.snapshotID, id)
        XCTAssertEqual(decoded.createdAt, now)
        XCTAssertEqual(decoded.phoneIterationDate, now.addingTimeInterval(-3))
        XCTAssertEqual(decoded.pumpStatus, snapshot.pumpStatus)
    }

    func test_emptyPayload_encodesUnder30KB() throws {
        let snapshot = AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: Date(),
            phoneIterationDate: Date(),
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: PumpStatusSnapshot(
                reservoirUnitsRemaining: 100,
                lastBasalRateUnitsPerHour: 0.5,
                isSuspended: false,
                lastReadingDate: Date()
            ),
            activeOverride: nil
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertLessThan(data.count, 30 * 1024,
                          "Even an empty snapshot should be far under the 30 KB target")
    }

    func test_roundTrip_preservesActiveOverride() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let override = TemporaryScheduleOverride(
            context: .preMeal,
            settings: TemporaryScheduleOverrideSettings(
                unit: .milligramsPerDeciliter,
                targetRange: DoubleRange(minValue: 80, maxValue: 90),
                insulinNeedsScaleFactor: nil
            ),
            startDate: now,
            duration: .finite(.minutes(60)),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
        let snapshot = AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: now,
            phoneIterationDate: now,
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: PumpStatusSnapshot(reservoirUnitsRemaining: 100,
                                           lastBasalRateUnitsPerHour: 0.5,
                                           isSuspended: false,
                                           lastReadingDate: now),
            activeOverride: override
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AlgorithmStateSnapshot.self, from: data)
        XCTAssertEqual(decoded.activeOverride, snapshot.activeOverride)
    }
}
