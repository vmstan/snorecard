import XCTest
@testable import SnorecardKit

final class NightlySleepSummaryTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(
        _ stage: SleepStageSample.Stage,
        startSeconds: TimeInterval,
        durationSeconds: TimeInterval
    ) -> SleepStageSample {
        SleepStageSample(
            stage: stage,
            start: anchor.addingTimeInterval(startSeconds),
            end: anchor.addingTimeInterval(startSeconds + durationSeconds),
            sourceBundleID: "test"
        )
    }

    func testStageSecondsAggregateCorrectly() {
        let samples = [
            sample(.deep, startSeconds: 0, durationSeconds: 1800),       // 30m
            sample(.core, startSeconds: 1800, durationSeconds: 7200),    // 2h
            sample(.rem, startSeconds: 9000, durationSeconds: 3600),     // 1h
            sample(.awake, startSeconds: 12600, durationSeconds: 600)    // 10m
        ]
        let summary = NightlySleepSummary.aggregate(
            nightDate: anchor,
            samples: samples
        )
        XCTAssertEqual(summary.deepSeconds, 1800)
        XCTAssertEqual(summary.coreSeconds, 7200)
        XCTAssertEqual(summary.remSeconds, 3600)
        XCTAssertEqual(summary.awakeSeconds, 600)
        XCTAssertEqual(summary.timeAsleep, 1800 + 7200 + 3600)
    }

    func testTimeInBedUsesEnvelopeNotSum() {
        // Two overlapping inBed records — the envelope is 8h but the
        // sum is 12h. We must use the envelope to avoid double-
        // counting Apple's blanket "in bed" rows.
        let samples = [
            sample(.inBed, startSeconds: 0, durationSeconds: 8 * 3600),
            sample(.inBed, startSeconds: 1 * 3600, durationSeconds: 4 * 3600)
        ]
        let summary = NightlySleepSummary.aggregate(
            nightDate: anchor,
            samples: samples
        )
        XCTAssertEqual(summary.timeInBed, 8 * 3600, accuracy: 0.001)
    }

    func testTimeInBedFallsBackToAsleepEnvelopeWhenNoInBedRecords() {
        // Some third-party trackers don't emit `.inBed` rows. Falling
        // back to the asleep envelope keeps the in-bed window UI
        // showing something useful.
        // deep:  [1800, 3600)
        // core:  [3600, 7200)
        // Envelope: 1800 → 7200 = 5400s wide.
        let samples = [
            sample(.deep, startSeconds: 1800, durationSeconds: 1800),
            sample(.core, startSeconds: 3600, durationSeconds: 3600)
        ]
        let summary = NightlySleepSummary.aggregate(
            nightDate: anchor,
            samples: samples
        )
        XCTAssertNotNil(summary.inBedStart)
        XCTAssertNotNil(summary.inBedEnd)
        XCTAssertEqual(summary.inBedEnd!.timeIntervalSince(summary.inBedStart!),
                       5400,
                       accuracy: 1.0)
    }

    func testCodableRoundTripPreservesSamples() throws {
        let samples = [
            sample(.deep, startSeconds: 0, durationSeconds: 1800),
            sample(.rem, startSeconds: 1800, durationSeconds: 1800)
        ]
        let summary = NightlySleepSummary.aggregate(
            nightDate: anchor,
            samples: samples
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(NightlySleepSummary.self, from: data)
        XCTAssertEqual(decoded.samples.count, 2)
        XCTAssertEqual(decoded.deepSeconds, summary.deepSeconds)
        XCTAssertEqual(decoded.schemaVersion, NightlySleepSummary.currentSchemaVersion)
    }

    func testFractionAsleepIsZeroForEmptyNight() {
        let summary = NightlySleepSummary.aggregate(
            nightDate: anchor,
            samples: []
        )
        XCTAssertEqual(summary.fractionAsleep(in: .deep), 0)
        XCTAssertEqual(summary.fractionAsleep(in: .rem), 0)
    }
}
