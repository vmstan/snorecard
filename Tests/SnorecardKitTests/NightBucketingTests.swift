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

    func testNightKeyIsRecordingStartDate() {
        // 22:00 UTC sleep → 06:00 UTC wake on Nov 14/15. The session
        // started on Nov 14, which is the day ResMed files this
        // recording under — so the night key must be Nov 14, even
        // though the user wakes up on Nov 15. Apple Health uses
        // wake-up date; we don't, because matching ResMed's folder
        // naming is what keeps the day card aligned with the CPAP
        // session window.
        let dayStart = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 2023, month: 11, day: 14, hour: 22
            )
        )!
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
        XCTAssertEqual(calendar.component(.day, from: key!), 14)
        XCTAssertEqual(calendar.component(.month, from: key!), 11)
        XCTAssertEqual(calendar.component(.year, from: key!), 2023)
    }

    func testBucketByNightPicksLongestSessionPerDate() {
        // Two sessions on the same calendar day — a daytime nap and
        // a (rather unconventional) start-on-the-same-day main
        // sleep. The longer one must win the dictionary slot so a
        // short nap never displaces the night view.
        let napStart = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2023, month: 11, day: 14, hour: 12
        ))!
        let napSamples = [
            SleepStageSample(stage: .core, start: napStart,
                             end: napStart.addingTimeInterval(20 * 60),
                             sourceBundleID: "test")
        ]
        // 4 h after the nap — past the 90-min cluster gap, but still
        // on the same calendar day so the night-key collision occurs.
        let mainStart = napStart.addingTimeInterval(4 * 3600)
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
        XCTAssertEqual(
            result.keys.count, 1,
            "Both sessions land on Nov 14 — longest-wins should leave one entry"
        )
        let surviving = result.values.first ?? []
        XCTAssertTrue(
            surviving.contains(where: { $0.stage == .deep }),
            "Main-night samples should be the surviving session"
        )
        XCTAssertFalse(
            surviving.contains(where: { $0.duration < 30 * 60 && $0.stage == .core }),
            "Short nap should have been replaced by the longer session"
        )
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(NightBucketing.sessions(from: []).isEmpty)
        XCTAssertTrue(NightBucketing.bucketByNight(samples: []).isEmpty)
        XCTAssertTrue(
            NightBucketing.bucketAgainstCPAPDays(
                samples: [],
                cpapWindows: []
            ).isEmpty
        )
    }

    func testBucketAgainstCPAPDaysAttachesMidnightCrossingSessionToRecordingStartDay() {
        // CPAP recording: 23:45 Nov 14 → 06:30 Nov 15 (~6h45m).
        // Watch session: full continuous sleep across the same window.
        // The watch session should land on Nov 14 (the recording-
        // start day) even though its midpoint falls on Nov 15 —
        // that's the entire reason this overlap rule exists.
        let recordingStart = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2023, month: 11, day: 14, hour: 23, minute: 45
        ))!
        let nightKeyNov14 = calendar.startOfDay(for: recordingStart)

        let watchStart = recordingStart.addingTimeInterval(-15 * 60)
        let watchEnd = recordingStart.addingTimeInterval(6 * 3600 + 45 * 60)
        let session = [
            SleepStageSample(stage: .inBed, start: watchStart, end: watchEnd,
                             sourceBundleID: "test"),
            SleepStageSample(stage: .deep,
                             start: watchStart.addingTimeInterval(30 * 60),
                             end: watchStart.addingTimeInterval(2 * 3600),
                             sourceBundleID: "test"),
            SleepStageSample(stage: .core,
                             start: watchStart.addingTimeInterval(2 * 3600),
                             end: watchStart.addingTimeInterval(6 * 3600),
                             sourceBundleID: "test")
        ]

        let cpapWindow = NightBucketing.CPAPDayWindow(
            nightKey: nightKeyNov14,
            start: recordingStart.addingTimeInterval(-30 * 60),
            end: recordingStart.addingTimeInterval(7 * 3600 + 30 * 60)
        )

        let bucketed = NightBucketing.bucketAgainstCPAPDays(
            samples: session,
            cpapWindows: [cpapWindow],
            calendar: calendar
        )

        XCTAssertNotNil(bucketed[nightKeyNov14])
        XCTAssertEqual(
            bucketed[nightKeyNov14]?.count, session.count,
            "Whole midnight-crossing session should attach to the recording-start day"
        )
        XCTAssertEqual(
            bucketed.keys.count, 1,
            "Watch session should not also land on Nov 15 — overlap pinned it to Nov 14"
        )
    }

    func testBucketAgainstCPAPDaysFallsBackToSessionStartWhenNoOverlap() {
        // Watch session with no CPAP windows in range — fallback
        // bucketing must still produce a sensible night key
        // (session-start calendar date) so the data isn't dropped.
        let start = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2023, month: 11, day: 20, hour: 23, minute: 30
        ))!
        let session = [
            SleepStageSample(stage: .inBed, start: start,
                             end: start.addingTimeInterval(6 * 3600),
                             sourceBundleID: "test")
        ]
        let bucketed = NightBucketing.bucketAgainstCPAPDays(
            samples: session,
            cpapWindows: [],
            calendar: calendar
        )
        let key = bucketed.keys.first
        XCTAssertNotNil(key)
        XCTAssertEqual(calendar.component(.day, from: key!), 20)
    }

    func testBucketAgainstCPAPDaysPicksLargestOverlapWhenMultipleWindows() {
        // Two adjacent CPAP days: Day A (Nov 14, ends 02:00 Nov 15)
        // and Day B (Nov 15, starts 22:00 Nov 15). Watch session
        // 23:00 Nov 14 → 06:00 Nov 15 overlaps Day A by 3 h and
        // Day B by 0 h — must attach to Day A.
        let nov14Start = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2023, month: 11, day: 14, hour: 23
        ))!
        let nov14Midnight = calendar.startOfDay(for: nov14Start)
        let nov15Midnight = calendar.date(byAdding: .day, value: 1, to: nov14Midnight)!

        let dayA = NightBucketing.CPAPDayWindow(
            nightKey: nov14Midnight,
            start: nov14Start,
            end: nov14Start.addingTimeInterval(3 * 3600) // → 02:00 Nov 15
        )
        let dayB = NightBucketing.CPAPDayWindow(
            nightKey: nov15Midnight,
            // Day-B window opens later that evening — no overlap
            // with this session.
            start: nov14Start.addingTimeInterval(23 * 3600),
            end: nov14Start.addingTimeInterval(30 * 3600)
        )
        let session = [
            SleepStageSample(stage: .inBed, start: nov14Start,
                             end: nov14Start.addingTimeInterval(7 * 3600),
                             sourceBundleID: "test")
        ]
        let bucketed = NightBucketing.bucketAgainstCPAPDays(
            samples: session,
            cpapWindows: [dayA, dayB],
            calendar: calendar
        )
        XCTAssertNotNil(bucketed[nov14Midnight])
        XCTAssertNil(bucketed[nov15Midnight])
    }

    func testNightKeyWithOnlyAwakeSamplesStillProducesAKey() {
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
