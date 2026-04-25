import XCTest
@testable import SnorecardKit

final class NightBucketingTests: XCTestCase {

    // Fixed reference calendar so the test produces the same `nightKey`
    // regardless of the host machine's timezone. UTC keeps the
    // arithmetic obvious — the production path uses `Calendar.current`,
    // which is also what the importer uses for ResMed day folders.
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// Helper — build a sample at offset hours from a fixed anchor.
    private func sample(
        _ stage: SleepStageSample.Stage,
        startHours: Double,
        durationHours: Double,
        anchor: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SleepStageSample {
        let start = anchor.addingTimeInterval(startHours * 3600)
        let end = start.addingTimeInterval(durationHours * 3600)
        return SleepStageSample(
            stage: stage,
            start: start,
            end: end,
            sourceBundleID: "com.test"
        )
    }

    func testSingleSessionClustersTogether() {
        let samples = [
            sample(.inBed, startHours: 0, durationHours: 8),
            sample(.core, startHours: 0.1, durationHours: 1.0),
            sample(.deep, startHours: 1.2, durationHours: 0.8),
            sample(.rem, startHours: 2.0, durationHours: 0.5)
        ]
        XCTAssertEqual(NightBucketing.sessions(from: samples).count, 1)
    }

    func testSplitsOnLongGap() {
        let nap = [
            sample(.core, startHours: 0, durationHours: 0.5)
        ]
        let mainNight = [
            // 4 hours later — well past the 90-minute gap.
            sample(.inBed, startHours: 4, durationHours: 7.5),
            sample(.deep, startHours: 4.2, durationHours: 0.6)
        ]
        let sessions = NightBucketing.sessions(from: nap + mainNight)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].count, 1, "Nap is its own cluster")
        XCTAssertEqual(sessions[1].count, 2, "Main night is its own cluster")
    }

    func testNightKeyIsWakeUpDate() {
        // 22:00 UTC sleep → 06:00 UTC wake. Mid-asleep is 02:00 UTC,
        // so the night key should be the wake-up day's midnight.
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        // 1_700_000_000 → 2023-11-14 22:13:20 UTC. Snap to 22:00 UTC.
        let dayStart = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 2023, month: 11, day: 14, hour: 22
            )
        )!
        _ = anchor
        let session = [
            SleepStageSample(stage: .inBed, start: dayStart,
                             end: dayStart.addingTimeInterval(8 * 3600),
                             sourceBundleID: "test"),
            SleepStageSample(stage: .deep, start: dayStart.addingTimeInterval(0.5 * 3600),
                             end: dayStart.addingTimeInterval(2 * 3600),
                             sourceBundleID: "test"),
            SleepStageSample(stage: .core, start: dayStart.addingTimeInterval(2 * 3600),
                             end: dayStart.addingTimeInterval(7 * 3600),
                             sourceBundleID: "test")
        ]
        let key = NightBucketing.nightKey(for: session, calendar: calendar)
        XCTAssertEqual(
            calendar.component(.day, from: key!), 15,
            "Mid-asleep at ~02:30 UTC means the night belongs to Nov 15"
        )
    }

    func testBucketByNightPicksLongestSessionPerDate() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let napStart = anchor
        let napSamples = [
            SleepStageSample(stage: .core, start: napStart,
                             end: napStart.addingTimeInterval(20 * 60),
                             sourceBundleID: "test")
        ]
        let mainStart = napStart.addingTimeInterval(6 * 3600)
        let mainSamples = [
            SleepStageSample(stage: .inBed, start: mainStart,
                             end: mainStart.addingTimeInterval(7 * 3600),
                             sourceBundleID: "test"),
            SleepStageSample(stage: .deep, start: mainStart.addingTimeInterval(0.5 * 3600),
                             end: mainStart.addingTimeInterval(6.5 * 3600),
                             sourceBundleID: "test")
        ]
        let result = NightBucketing.bucketByNight(
            samples: napSamples + mainSamples,
            calendar: calendar
        )
        // Both sessions might land on the same calendar day; the
        // longer (main night) must win regardless.
        let allValues = result.values.flatMap { $0 }
        XCTAssertTrue(
            allValues.contains(where: { $0.stage == .deep }),
            "Main-night samples should be the surviving session"
        )
        XCTAssertFalse(
            allValues.contains(where: { $0.duration < 30 * 60 && $0.stage == .core }),
            "Short nap should have been replaced by the longer session"
        )
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(NightBucketing.sessions(from: []).isEmpty)
        XCTAssertTrue(NightBucketing.bucketByNight(samples: []).isEmpty)
    }

    func testNightKeyWithOnlyAwakeSamplesFallsBackToFullPool() {
        // No asleep samples — bucketing should still hand back a key
        // based on the awake/in-bed timestamps so an `inBed`-only
        // session (third-party tracker) doesn't silently disappear.
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let session = [
            SleepStageSample(stage: .inBed, start: anchor,
                             end: anchor.addingTimeInterval(8 * 3600),
                             sourceBundleID: "test"),
            SleepStageSample(stage: .awake, start: anchor.addingTimeInterval(3 * 3600),
                             end: anchor.addingTimeInterval(3.5 * 3600),
                             sourceBundleID: "test")
        ]
        XCTAssertNotNil(NightBucketing.nightKey(for: session, calendar: calendar))
    }
}
