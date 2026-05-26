import XCTest
@testable import SnorecardKit

/// Exercise the per-breath NED / FI / M-shape pass and the
/// sequence-level RERA detector against synthetic flow signals so
/// the algorithm's response to each idealised breath shape is
/// pinned down before real data goes through it.
///
/// All fixtures are 25 Hz, L/min — the same units `BreathDetector`
/// expects. `makeFlow(breaths:profile:)` stitches a given number
/// of identical breath cycles into one array; per-breath NED
/// sequences are built via `makeFlow(perBreathNED:)`, which shapes
/// each breath so the midpoint sample sits at the target NED.
final class NEDAnalysisTests: XCTestCase {

    func testEmptyInputReturnsNil() {
        XCTAssertNil(
            NEDAnalysis.compute(
                flowLPerMin: [],
                sampleRate: BreathDetector.sampleRateHz,
                sessionStart: Date()
            )
        )
    }

    func testTooShortInputReturnsNil() {
        // 50 samples = 2 s @ 25 Hz, below the
        // `BreathDetector.minWindow * 4 = 100` floor.
        let short = Array(repeating: 0.0, count: 50)
        XCTAssertNil(
            NEDAnalysis.compute(
                flowLPerMin: short,
                sampleRate: BreathDetector.sampleRateHz,
                sessionStart: Date()
            )
        )
    }

    func testSinusoidalBreathsHaveLowNED() {
        // ~12 breaths per minute (75 samples per cycle @ 25 Hz),
        // ±25 L/min — a clean parabolic inspiration with Qmid ~= Qpeak.
        let n = 60 * Int(BreathDetector.sampleRateHz)
        let flow = (0..<n).map { i in
            25.0 * sin(2 * .pi * Double(i) / 75.0)
        }
        guard let result = NEDAnalysis.compute(
            flowLPerMin: flow,
            sampleRate: BreathDetector.sampleRateHz,
            sessionStart: Date()
        ) else {
            return XCTFail("Sinusoid produced no result")
        }
        XCTAssertLessThan(result.breakdown.nedMean, 0.10,
            "Sine breaths should report near-zero NED, got \(result.breakdown.nedMean)")
        // The narrow peak of a sine wave doesn't dwell long within
        // 10% of Qpeak — FI should be modest, not "flow-limited."
        XCTAssertLessThan(result.breakdown.flatBreathFraction, 0.20)
    }

    func testSquarePlateauBreathsHaveLowNEDHighFI() {
        // Plateau breath: 0.6s ramp up, 1.4s plateau at +30, 0.5s ramp
        // down, 1.5s expiration to -25. 4.0s cycle = 15/min.
        let cycle: [Double] = makeSquarePlateauCycle()
        let flow = Array(repeating: cycle, count: 18).flatMap { $0 }
        guard let result = NEDAnalysis.compute(
            flowLPerMin: flow,
            sampleRate: BreathDetector.sampleRateHz,
            sessionStart: Date()
        ) else {
            return XCTFail("Square plateau produced no result")
        }
        XCTAssertGreaterThan(result.breakdown.flatBreathFraction, 0.85,
            "Plateau breaths should mostly flag flow-limited (FI ≥ 0.85), got \(result.breakdown.flatBreathFraction)")
        XCTAssertLessThan(result.breakdown.nedMean, 0.20,
            "Plateau breath Qmid ≈ Qpeak, so NED should stay low, got \(result.breakdown.nedMean)")
    }

    func testNegativeEffortBreathsHaveHighNED() {
        // Sawtooth: 0.3s ramp to +30, 1.5s linear decay to +5, then a
        // 2s expiration to -25. Qmid lands halfway down the decay, so
        // (Qpeak - Qmid) / Qpeak should sit in the high range.
        let cycle = makeSawtoothCycle()
        let flow = Array(repeating: cycle, count: 18).flatMap { $0 }
        guard let result = NEDAnalysis.compute(
            flowLPerMin: flow,
            sampleRate: BreathDetector.sampleRateHz,
            sessionStart: Date()
        ) else {
            return XCTFail("Sawtooth produced no result")
        }
        XCTAssertGreaterThan(result.breakdown.nedMean, 0.30,
            "Sawtooth breaths should report high NED, got \(result.breakdown.nedMean)")
    }

    func testRERASequenceFiresOneEvent() {
        // Per-breath NED targets: 0.05, 0.10, 0.15, 0.22, 0.28, 0.05.
        // Three rising deltas (≥ 0.04 each) + a recovery breath that
        // drops by 0.23 → one event, runLength 5.
        let neds: [Double] = [0.05, 0.10, 0.15, 0.22, 0.28, 0.05]
        let per = makePerBreathMetrics(neds: neds)
        let events = NEDAnalysis.detectRERAs(per: per)
        XCTAssertEqual(events.count, 1)
        if let event = events.first {
            XCTAssertGreaterThanOrEqual(event.runLength, 3)
        }
    }

    func testRERANonProgressiveSequenceDoesNotFire() {
        // Alternating values never produce three consecutive
        // ≥ 0.04 rises, so no run gets long enough.
        let neds: [Double] = [0.05, 0.30, 0.05, 0.30, 0.05, 0.30]
        let per = makePerBreathMetrics(neds: neds)
        let events = NEDAnalysis.detectRERAs(per: per)
        XCTAssertEqual(events.count, 0)
    }

    func testRERAWithoutRecoveryDoesNotFire() {
        // Five-breath rising series ending high — no recovery breath
        // means no event closes out.
        let neds: [Double] = [0.05, 0.10, 0.15, 0.22, 0.30]
        let per = makePerBreathMetrics(neds: neds)
        let events = NEDAnalysis.detectRERAs(per: per)
        XCTAssertEqual(events.count, 0)
    }

    func testRecoveryBreathTooHighDoesNotFire() {
        // Same rising shape, but the "recovery" breath only drops to
        // 0.22 — above `reraRecoveryAbsMax = 0.20`. The detector
        // should refuse to close the event.
        let neds: [Double] = [0.05, 0.10, 0.15, 0.22, 0.28, 0.22]
        let per = makePerBreathMetrics(neds: neds)
        let events = NEDAnalysis.detectRERAs(per: per)
        XCTAssertEqual(events.count, 0)
    }

    func testBreakdownAccumulatorMatchesSinglePass() {
        // Build two short sinusoidal halves, run the detector
        // separately, accumulate the breakdowns, and confirm the
        // result equals the breakdown of the concatenated signal.
        let halfA = (0..<(60 * Int(BreathDetector.sampleRateHz))).map { i in
            25.0 * sin(2 * .pi * Double(i) / 75.0)
        }
        let halfB = halfA  // identical second half
        let combined = halfA + halfB

        guard let single = NEDAnalysis.compute(
            flowLPerMin: combined,
            sampleRate: BreathDetector.sampleRateHz,
            sessionStart: Date()
        ),
        let a = NEDAnalysis.compute(
            flowLPerMin: halfA,
            sampleRate: BreathDetector.sampleRateHz,
            sessionStart: Date()
        ),
        let b = NEDAnalysis.compute(
            flowLPerMin: halfB,
            sampleRate: BreathDetector.sampleRateHz,
            sessionStart: Date()
        ) else {
            return XCTFail("Accumulator inputs produced no result")
        }

        var acc = NEDAnalysis.BreakdownAccumulator()
        acc.add(a.breakdown, weight: Double(a.breakdown.analysedBreaths))
        acc.add(b.breakdown, weight: Double(b.breakdown.analysedBreaths))
        let merged = acc.finalize(
            totalWeight: Double(a.breakdown.analysedBreaths + b.breakdown.analysedBreaths),
            analysedBreaths: a.breakdown.analysedBreaths + b.breakdown.analysedBreaths
        )

        // Equal halves → the accumulator result matches each half
        // (and matches the single concatenated pass within the
        // sub-sample boundary noise from where one half ends).
        XCTAssertEqual(merged.nedMean, a.breakdown.nedMean, accuracy: 0.01)
        XCTAssertEqual(merged.flatBreathFraction, a.breakdown.flatBreathFraction, accuracy: 0.01)
        XCTAssertEqual(merged.mShapeFraction, a.breakdown.mShapeFraction, accuracy: 0.01)
        // Combined signal's NED should be in the same band as the
        // halves — the breath stitched across the join may add a
        // hair of noise but mustn't shift the population mean.
        XCTAssertEqual(single.breakdown.nedMean, merged.nedMean, accuracy: 0.05)
    }

    func testDailyStatisticsCodableRoundTripPreservesRERAFields() throws {
        let breakdown = NEDAnalysis.Breakdown(
            nedMean: 0.18,
            ned95: 0.42,
            flatBreathFraction: 0.31,
            mShapeFraction: 0.07,
            analysedBreaths: 4_823
        )
        var stats = DailyStatistics(
            date: Date(timeIntervalSince1970: 1_750_000_000),
            usageMinutes: 420,
            maskEvents: 1,
            ahi: 1.4,
            hypopneaIndex: 0.5,
            apneaIndex: 0.9,
            obstructiveApneaIndex: 0.5,
            centralApneaIndex: 0.3,
            unspecifiedApneaIndex: 0.1,
            pressureMedian: 8.2,
            pressureMax: 12.4,
            leak95LPerMin: 8.0,
            leakMaxLPerMin: 14.0,
            reraIndex: 4.7,
            flowLimit95: 0.05,
            minuteVentilation50: 7.2,
            respirationRate50: 13.0,
            tidalVolume50: 0.55,
            modeCode: 1,
            productName: "AirSense 10 CPAP"
        )
        stats.nedAnalysisBreakdown = breakdown

        let encoded = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(DailyStatistics.self, from: encoded)
        XCTAssertEqual(decoded.reraIndex, 4.7)
        XCTAssertEqual(decoded.nedAnalysisBreakdown, breakdown)
    }

    func testLegacyJSONWithoutRERAFieldsDecodesToNil() throws {
        // A v7-era sidecar payload — no reraIndex / nedAnalysisBreakdown.
        // Should still decode cleanly with both new fields as nil so
        // older caches don't crash the app on launch.
        let legacy = """
        {
            "date": 1750000000,
            "usageMinutes": 420,
            "maskEvents": 1,
            "ahi": 1.4,
            "hypopneaIndex": 0.5,
            "apneaIndex": 0.9,
            "obstructiveApneaIndex": 0.5,
            "centralApneaIndex": 0.3,
            "unspecifiedApneaIndex": 0.1,
            "pressureMedian": 8.2,
            "pressureMax": 12.4,
            "leak95LPerMin": 8.0,
            "leakMaxLPerMin": 14.0,
            "flowLimit95": 0.05,
            "minuteVentilation50": 7.2,
            "respirationRate50": 13.0,
            "tidalVolume50": 0.55,
            "modeCode": 1,
            "productName": "AirSense 10 CPAP"
        }
        """
        let data = legacy.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DailyStatistics.self, from: data)
        XCTAssertNil(decoded.reraIndex)
        XCTAssertNil(decoded.nedAnalysisBreakdown)
    }

    // MARK: - Fixtures

    /// One ~4.5-second top-hat breath cycle. The ramps are short
    /// (0.16s each) on purpose: FI ≥ 0.85 requires 85% of the
    /// inspiration samples to sit within 10% of peak, so the
    /// plateau has to dominate the inspiratory span.
    private func makeSquarePlateauCycle() -> [Double] {
        var out: [Double] = []
        let rate = Int(BreathDetector.sampleRateHz)
        let rampUp = Int(0.16 * Double(rate))
        let plateau = Int(2.6 * Double(rate))
        let rampDown = Int(0.16 * Double(rate))
        let expirationSamples = Int(1.6 * Double(rate))
        for i in 0..<rampUp { out.append(30 * Double(i) / Double(rampUp)) }
        for _ in 0..<plateau { out.append(30) }
        for i in 0..<rampDown { out.append(30 * (1 - Double(i) / Double(rampDown))) }
        // Expiration as a half-sine dipping to -25 then back to 0.
        for i in 0..<expirationSamples {
            let phase = Double(i) / Double(expirationSamples)
            out.append(-25 * sin(.pi * phase))
        }
        return out
    }

    /// One 4-second sawtooth breath cycle. Peak +30 at 0.3s, linear
    /// decay to +5 over 1.5s, then expiration mirrors the plateau
    /// cycle.
    private func makeSawtoothCycle() -> [Double] {
        var out: [Double] = []
        let rate = Int(BreathDetector.sampleRateHz)
        let rampUp = Int(0.3 * Double(rate))
        let decay = Int(1.5 * Double(rate))
        let expirationSamples = Int(2.2 * Double(rate))
        for i in 0..<rampUp { out.append(30 * Double(i) / Double(rampUp)) }
        for i in 0..<decay {
            let t = Double(i) / Double(decay)
            out.append(30 - 25 * t)
        }
        for i in 0..<expirationSamples {
            let phase = Double(i) / Double(expirationSamples)
            out.append(-25 * sin(.pi * phase))
        }
        return out
    }

    /// Build a `BreathMetrics` array whose `.ned` values match the
    /// supplied targets exactly. The other fields stay neutral so
    /// the RERA detector's only sensitivity is to the NED series.
    private func makePerBreathMetrics(neds: [Double]) -> [NEDAnalysis.BreathMetrics] {
        return neds.enumerated().map { idx, ned in
            NEDAnalysis.BreathMetrics(
                ned: ned,
                fi: 0,
                isMShape: false,
                sampleIndex: idx * 100
            )
        }
    }
}
