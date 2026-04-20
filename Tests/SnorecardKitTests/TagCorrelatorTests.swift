import XCTest
@testable import SnorecardKit

final class TagCorrelatorTests: XCTestCase {
    func testReturnsEmptyBelowMinimumRangeSize() {
        let days = (0..<5).map { day in
            TagCorrelator.DayInput(tags: [], stats: makeStats(day: day, ahi: 3))
        }
        XCTAssertTrue(TagCorrelator.correlate(days: days).isEmpty)
    }

    func testReturnsEmptyBelowPerGroupMinimum() {
        var days: [TagCorrelator.DayInput] = []
        // 10 nights, but only 2 tagged — below the per-group minimum.
        for day in 0..<10 {
            let tags: Set<NoteTag> = day < 2 ? [.alcohol] : []
            days.append(TagCorrelator.DayInput(tags: tags, stats: makeStats(day: day, ahi: 3)))
        }
        XCTAssertTrue(TagCorrelator.correlate(days: days).isEmpty)
    }

    func testEmitsObservationAboveThresholds() {
        var days: [TagCorrelator.DayInput] = []
        // 6 tagged nights with high AHI, 6 untagged nights with low AHI.
        for day in 0..<12 {
            let tagged = day < 6
            days.append(TagCorrelator.DayInput(
                tags: tagged ? [.alcohol] : [],
                stats: makeStats(day: day, ahi: tagged ? 6.0 : 2.0)
            ))
        }
        let observations = TagCorrelator.correlate(days: days)
        let ahiObs = observations.first { $0.tag == .alcohol && $0.metric == .ahi }
        XCTAssertNotNil(ahiObs)
        XCTAssertEqual(ahiObs?.taggedNights, 6)
        XCTAssertEqual(ahiObs?.untaggedNights, 6)
        XCTAssertEqual(ahiObs?.delta ?? 0, 4.0, accuracy: 0.2)
    }

    func testIgnoresDifferencesBelowNoiseFloor() {
        var days: [TagCorrelator.DayInput] = []
        // Difference in AHI of ~0.3 — below the 0.8 noise floor.
        for day in 0..<12 {
            let tagged = day < 6
            days.append(TagCorrelator.DayInput(
                tags: tagged ? [.stress] : [],
                stats: makeStats(day: day, ahi: tagged ? 3.0 : 2.7)
            ))
        }
        XCTAssertTrue(TagCorrelator.correlate(days: days).isEmpty)
    }

    private func makeStats(day: Int, ahi: Double) -> DailyStatistics {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let date = Calendar.current.date(byAdding: .day, value: day, to: start)!
        return DailyStatistics(
            date: date,
            usageMinutes: 420,
            maskEvents: 1,
            ahi: ahi,
            hypopneaIndex: 0,
            apneaIndex: 0,
            obstructiveApneaIndex: 0,
            centralApneaIndex: 0,
            unspecifiedApneaIndex: 0,
            pressureMedian: nil,
            pressure95: nil,
            pressureMax: nil,
            ipap95: nil,
            epap95: nil,
            leak95LPerMin: nil,
            leakMaxLPerMin: nil,
            timeInApneaSeconds: nil,
            largeLeakSeconds: nil,
            glasgowIndex: nil,
            flowLimit95: nil,
            minuteVentilation50: nil,
            respirationRate50: nil,
            tidalVolume50: nil,
            modeCode: nil,
            productName: nil
        )
    }
}
