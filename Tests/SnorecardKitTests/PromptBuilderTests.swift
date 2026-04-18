import XCTest
@testable import SnorecardKit

final class PromptBuilderTests: XCTestCase {
    func testNightSummaryPromptIncludesInputJSON() {
        let input = NightSummaryInput(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            usageHours: 7.2,
            ahi: 3.1,
            glasgowIndex: 1.82,
            pressure95: 11.4,
            eprSupport: 2.0,
            leak95LPerMin: 6,
            largeLeakPercent: 0.2,
            timeInApneaPercent: 0.8,
            tidalVolumeMedianML: 480,
            baselineDiff: NightSummaryInput.BaselineDiff(
                ahiDelta: -0.8,
                usageHoursDelta: 0.4,
                leakDelta: 0,
                giDelta: -0.1
            ),
            userNote: "Felt congested, allergy meds at 9pm"
        )
        let prompt = NightSummaryPrompt.buildPrompt(input: input)
        XCTAssertTrue(prompt.contains("\"ahi\""))
        XCTAssertTrue(prompt.contains("\"usageHours\""))
        XCTAssertTrue(prompt.contains("congested"))
        XCTAssertTrue(prompt.contains("headline"))
        XCTAssertTrue(prompt.contains("paragraph"))
    }

    func testNightSummaryPromptOmitsNilMetricsInJSON() {
        let input = NightSummaryInput(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            usageHours: 6.5,
            ahi: 2.0,
            glasgowIndex: nil,
            pressure95: nil,
            eprSupport: nil,
            leak95LPerMin: nil,
            largeLeakPercent: nil,
            timeInApneaPercent: nil,
            tidalVolumeMedianML: nil,
            baselineDiff: nil,
            userNote: nil
        )
        let prompt = NightSummaryPrompt.buildPrompt(input: input)
        XCTAssertFalse(prompt.contains("\"glasgowIndex\""))
        XCTAssertFalse(prompt.contains("\"pressure95\""))
        XCTAssertFalse(prompt.contains("\"userNote\""))
    }

    func testSystemInstructionsForbidAdvisoryLanguage() {
        XCTAssertTrue(
            NightSummaryPrompt.systemInstructions.contains("Never give advice")
        )
        XCTAssertTrue(
            OverviewNarrativePrompt.systemInstructions.contains("Never give advice")
        )
        XCTAssertTrue(
            MetricExplainPrompt.systemInstructions.contains("Never give advice")
        )
    }

    func testInputBuilderRoundsNightSummaryFields() {
        let stats = DailyStatistics(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            usageMinutes: 434.7,
            maskEvents: 1,
            ahi: 3.14159,
            hypopneaIndex: 0,
            apneaIndex: 0,
            obstructiveApneaIndex: 0,
            centralApneaIndex: 0,
            unspecifiedApneaIndex: 0,
            pressureMedian: 9.0,
            pressure95: 11.4567,
            pressureMax: nil,
            ipap95: 13.2,
            epap95: 11.1,
            leak95LPerMin: 6.3,
            leakMaxLPerMin: nil,
            timeInApneaSeconds: 240,
            largeLeakSeconds: 60,
            glasgowIndex: 1.8234,
            flowLimit95: nil,
            minuteVentilation50: nil,
            respirationRate50: nil,
            tidalVolume50: 0.4812,
            modeCode: nil,
            productName: nil
        )
        let input = IntelligenceInputBuilder.nightSummary(
            stats: stats,
            baseline: nil,
            userNote: "  well rested  "
        )
        XCTAssertEqual(input.usageHours, 7.2, accuracy: 0.0001)
        XCTAssertEqual(input.ahi, 3.1, accuracy: 0.0001)
        XCTAssertEqual(input.glasgowIndex, 1.82)
        XCTAssertEqual(input.pressure95, 11.5)
        XCTAssertEqual(input.eprSupport, 2.1)
        XCTAssertEqual(input.leak95LPerMin, 6)
        XCTAssertEqual(input.tidalVolumeMedianML, 481)
        XCTAssertEqual(input.userNote, "well rested")
    }

    func testInputBuilderRoundingStableAcrossTinyDrift() {
        let stats = makeStats(ahi: 3.1)
        let statsDrifted = makeStats(ahi: 3.1000002)
        let input = IntelligenceInputBuilder.nightSummary(
            stats: stats,
            baseline: nil,
            userNote: nil
        )
        let inputDrifted = IntelligenceInputBuilder.nightSummary(
            stats: statsDrifted,
            baseline: nil,
            userNote: nil
        )
        XCTAssertEqual(
            IntelligenceCache.hash(of: input),
            IntelligenceCache.hash(of: inputDrifted)
        )
    }

    private func makeStats(ahi: Double) -> DailyStatistics {
        DailyStatistics(
            date: Date(timeIntervalSince1970: 1_700_000_000),
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
