import XCTest
@testable import SnorecardKit

final class IntelligenceCacheTests: XCTestCase {
    func testHashIsStableAcrossEncodes() {
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
            baselineDiff: nil,
            userNote: nil
        )
        let h1 = IntelligenceCache.hash(of: input)
        let h2 = IntelligenceCache.hash(of: input)
        XCTAssertEqual(h1, h2)
        XCTAssertFalse(h1.isEmpty)
    }

    func testNightSummaryRoundTrip() throws {
        let folder = try createTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let output = NightSummaryOutput(
            headline: "Steady night overall",
            paragraph: "AHI sat at 3.1, close to your recent average."
        )
        let hash = "fake-hash"

        IntelligenceCache.saveNightSummary(
            output,
            inputHash: hash,
            templateVersion: NightSummaryPrompt.templateVersion,
            to: folder
        )

        let loaded = IntelligenceCache.loadNightSummary(
            for: folder,
            matching: hash,
            templateVersion: NightSummaryPrompt.templateVersion
        )
        XCTAssertEqual(loaded, output)
    }

    func testDifferentHashMisses() throws {
        let folder = try createTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let output = NightSummaryOutput(headline: "a", paragraph: "b")
        IntelligenceCache.saveNightSummary(
            output,
            inputHash: "hash-a",
            templateVersion: NightSummaryPrompt.templateVersion,
            to: folder
        )
        XCTAssertNil(IntelligenceCache.loadNightSummary(
            for: folder,
            matching: "hash-b",
            templateVersion: NightSummaryPrompt.templateVersion
        ))
    }

    func testTemplateVersionBumpInvalidates() throws {
        let folder = try createTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let output = NightSummaryOutput(headline: "a", paragraph: "b")
        IntelligenceCache.saveNightSummary(
            output,
            inputHash: "hash",
            templateVersion: 1,
            to: folder
        )
        XCTAssertNil(IntelligenceCache.loadNightSummary(
            for: folder,
            matching: "hash",
            templateVersion: 2
        ))
    }

    func testMetricExplainLRUTrimsToSeven() throws {
        let folder = try createTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Save one entry per explainable metric (7 total).
        for metric in ExplainableMetric.allCases {
            IntelligenceCache.saveMetricExplain(
                MetricExplainOutput(whatItMeans: metric.rawValue, howYoursLooks: "x"),
                metric: metric,
                inputHash: "h-\(metric.rawValue)",
                templateVersion: MetricExplainPrompt.templateVersion,
                to: folder
            )
        }
        let payload = IntelligenceCache.loadDay(for: folder)
        XCTAssertLessThanOrEqual(payload.metricExplains.count, 7)
    }

    private func createTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("snorecard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return folder
    }
}
