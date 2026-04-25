import XCTest
@testable import SnorecardKit

final class SleepStageCacheTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snorecard-sleep-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testRoundTripPreservesStageTotals() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            SleepStageSample(stage: .deep, start: anchor,
                             end: anchor.addingTimeInterval(1800),
                             sourceBundleID: "com.test"),
            SleepStageSample(stage: .core, start: anchor.addingTimeInterval(1800),
                             end: anchor.addingTimeInterval(5400),
                             sourceBundleID: "com.test")
        ]
        let summary = NightlySleepSummary.aggregate(
            nightDate: anchor,
            samples: samples
        )
        SleepStageCache.save(summary, to: tmpDir)
        let loaded = SleepStageCache.load(for: tmpDir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.deepSeconds, summary.deepSeconds)
        XCTAssertEqual(loaded?.coreSeconds, summary.coreSeconds)
        XCTAssertEqual(loaded?.samples.count, 2)
    }

    func testNilSaveDeletesExistingSidecar() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = NightlySleepSummary.aggregate(
            nightDate: anchor,
            samples: [
                SleepStageSample(stage: .deep, start: anchor,
                                 end: anchor.addingTimeInterval(600),
                                 sourceBundleID: "com.test")
            ]
        )
        SleepStageCache.save(summary, to: tmpDir)
        XCTAssertNotNil(SleepStageCache.load(for: tmpDir))
        SleepStageCache.save(nil, to: tmpDir)
        XCTAssertNil(SleepStageCache.load(for: tmpDir))
    }

    func testFutureSchemaVersionIsRejected() throws {
        // Hand-craft a payload with a future schemaVersion so the
        // cache reader has something to drop.
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let payload: [String: Any] = [
            "nightDate": ISO8601DateFormatter().string(from: anchor),
            "coreSeconds": 0,
            "remSeconds": 0,
            "deepSeconds": 0,
            "awakeSeconds": 0,
            "unspecifiedSeconds": 0,
            "timeAsleep": 0,
            "timeInBed": 0,
            "samples": [],
            "generatedAt": ISO8601DateFormatter().string(from: anchor),
            "schemaVersion": NightlySleepSummary.currentSchemaVersion + 1
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let url = tmpDir.appendingPathComponent(SleepStageCache.filename)
        try data.write(to: url)
        XCTAssertNil(
            SleepStageCache.load(for: tmpDir),
            "Future schema versions must be ignored, not partially decoded"
        )
    }
}
