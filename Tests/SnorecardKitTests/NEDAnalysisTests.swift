import XCTest
@testable import SnorecardKit

/// Exercise the per-breath NED / FI / M-shape pass and the
/// FL-run / acceptance-criteria RERA detector. The algorithm tracks
/// AirwayLab's NED engine; thresholds here match those constants in
/// fraction units (NED ∈ 0..1, vs AirwayLab's percentage 0..100).
///
/// Fixtures fall into two families:
///
/// * **Real-shape tests** synthesize 25 Hz flow signals (sine,
///   square plateau, sawtooth) and exercise the whole pipeline
///   end-to-end through `compute`.
/// * **RERA detector tests** feed hand-built `BreathMetrics`
///   arrays into `detectRERAs` directly so each acceptance path
///   (slope, recovery+sigh, sustained max NED) can be hit in
///   isolation without having to reverse-engineer a flow signal
///   that triggers it.
final class NEDAnalysisTests: XCTestCase {

    // MARK: - End-to-end real-shape tests

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
        // ±25 L/min. Sine is symmetric around its midpoint and the
        // mean of a half-sine is ~2/π of the peak (0.637) — well
        // below the 0.85 FI flow-limited threshold.
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
        XCTAssertLessThan(result.breakdown.flatBreathFraction, 0.20,
            "Half-sine mean/peak ≈ 0.64, below the 0.85 FI threshold")
    }

    func testSquarePlateauBreathsHaveLowNEDHighFI() {
        // Top-hat breath. Mean/peak ≈ 1 for the plateau-dominated
        // shape, so FI sits well above the 0.85 threshold.
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
        // Sawtooth: ramp to +30 fast, then decay over 1.5 s.
        // Qmid lands halfway down the decay, giving a NED in the
        // 0.3–0.5 range. The FL marker / RERA pipeline also fires
        // here because every breath has NED > 0.20 (the FL
        // threshold).
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

    // MARK: - RERA detector — acceptance paths

    func testEmptyPerBreathArrayProducesNoEvents() {
        XCTAssertEqual(NEDAnalysis.detectRERAs(per: []).count, 0)
    }

    func testTooShortRunDoesNotFire() {
        // Two flow-limited breaths surrounded by non-FL breaths —
        // run length 2, below the 3-breath minimum.
        let per = makePerBreathMetrics(
            specs: [
                (ned: 0.05, fi: 0.50, qPeak: 30),
                (ned: 0.25, fi: 0.50, qPeak: 30),
                (ned: 0.25, fi: 0.50, qPeak: 30),
                (ned: 0.05, fi: 0.50, qPeak: 30),
            ]
        )
        XCTAssertEqual(NEDAnalysis.detectRERAs(per: per).count, 0)
    }

    func testRunLongerThanFifteenBreathsDoesNotFire() {
        // 16 consecutive FL breaths followed by a recovery — the
        // 15-breath ceiling drops the candidate. AirwayLab caps at
        // 15 to keep persistent flow limitation (e.g. positional
        // CPAP gaps) from collapsing into one giant "event".
        var specs: [(ned: Double, fi: Double, qPeak: Double)] = []
        specs.append((ned: 0.05, fi: 0.50, qPeak: 30))
        for _ in 0..<16 {
            specs.append((ned: 0.25, fi: 0.50, qPeak: 30))
        }
        specs.append((ned: 0.05, fi: 0.50, qPeak: 30))
        let per = makePerBreathMetrics(specs: specs)
        XCTAssertEqual(NEDAnalysis.detectRERAs(per: per).count, 0)
    }

    func testSlopeAcceptanceFires() {
        // Five FL breaths whose NEDs ramp from 0.22 to 0.30
        // (slope ≈ 0.02 / breath, well above the 0.005 threshold).
        // Max NED stays below 0.34 and the next breath has neither
        // recovery nor sigh — so only the slope path can accept.
        let per = makePerBreathMetrics(
            specs: [
                (ned: 0.05, fi: 0.50, qPeak: 30),
                (ned: 0.22, fi: 0.60, qPeak: 30),
                (ned: 0.24, fi: 0.60, qPeak: 30),
                (ned: 0.26, fi: 0.60, qPeak: 30),
                (ned: 0.28, fi: 0.60, qPeak: 30),
                (ned: 0.30, fi: 0.60, qPeak: 30),
                (ned: 0.18, fi: 0.60, qPeak: 30),  // not a recovery (>= 0.10)
            ]
        )
        let events = NEDAnalysis.detectRERAs(per: per)
        XCTAssertEqual(events.count, 1)
        if let event = events.first {
            XCTAssertEqual(event.breathCount, 5)
            XCTAssertGreaterThan(event.nedSlope, NEDAnalysis.reraSlopeThreshold)
            XCTAssertLessThan(event.maxNED, NEDAnalysis.reraSustainedMaxNEDThreshold)
            XCTAssertFalse(event.hasRecovery)
            XCTAssertFalse(event.hasSigh)
        }
    }

    func testRecoveryAndSighAcceptanceFires() {
        // Flat NED at 0.25 across the run — slope is ~0 and
        // maxNED stays below 0.34. The following breath drops to
        // NED 0.05 and has 2× the run's Qpeak (clears both
        // recovery and sigh thresholds), so only that path can
        // accept.
        let per = makePerBreathMetrics(
            specs: [
                (ned: 0.05, fi: 0.50, qPeak: 30),
                (ned: 0.25, fi: 0.60, qPeak: 30),
                (ned: 0.25, fi: 0.60, qPeak: 30),
                (ned: 0.25, fi: 0.60, qPeak: 30),
                (ned: 0.25, fi: 0.60, qPeak: 30),
                (ned: 0.05, fi: 0.50, qPeak: 60),  // recovery + sigh
            ]
        )
        let events = NEDAnalysis.detectRERAs(per: per)
        XCTAssertEqual(events.count, 1)
        if let event = events.first {
            XCTAssertEqual(event.breathCount, 4)
            XCTAssertLessThan(abs(event.nedSlope), NEDAnalysis.reraSlopeThreshold)
            XCTAssertTrue(event.hasRecovery)
            XCTAssertTrue(event.hasSigh)
        }
    }

    func testRecoveryWithoutSighDoesNotFire() {
        // Same flat run as above, but the next breath only drops
        // NED (recovery) — its Qpeak is the same as the run's, so
        // no sigh. Slope and maxNED also fail. Nothing fires.
        let per = makePerBreathMetrics(
            specs: [
                (ned: 0.05, fi: 0.50, qPeak: 30),
                (ned: 0.25, fi: 0.60, qPeak: 30),
                (ned: 0.25, fi: 0.60, qPeak: 30),
                (ned: 0.25, fi: 0.60, qPeak: 30),
                (ned: 0.25, fi: 0.60, qPeak: 30),
                (ned: 0.05, fi: 0.50, qPeak: 30),  // recovery, no sigh
            ]
        )
        XCTAssertEqual(NEDAnalysis.detectRERAs(per: per).count, 0)
    }

    func testSustainedHighNEDAcceptanceFires() {
        // Three FL breaths above the 0.34 sustained threshold.
        // Slope is flat and the following breath is neither a
        // recovery nor a sigh — so only the sustained path can
        // accept.
        let per = makePerBreathMetrics(
            specs: [
                (ned: 0.05, fi: 0.50, qPeak: 30),
                (ned: 0.38, fi: 0.60, qPeak: 30),
                (ned: 0.38, fi: 0.60, qPeak: 30),
                (ned: 0.38, fi: 0.60, qPeak: 30),
                (ned: 0.18, fi: 0.60, qPeak: 30),  // FL drops, no recovery
            ]
        )
        let events = NEDAnalysis.detectRERAs(per: per)
        XCTAssertEqual(events.count, 1)
        if let event = events.first {
            XCTAssertGreaterThan(event.maxNED, NEDAnalysis.reraSustainedMaxNEDThreshold)
        }
    }

    func testNonConsecutiveFLBreathsDoNotFire() {
        // Alternating FL / non-FL breaths — no run of consecutive
        // FL breaths ever reaches the 3-breath minimum.
        let per = makePerBreathMetrics(
            specs: [
                (ned: 0.05, fi: 0.50, qPeak: 30),
                (ned: 0.30, fi: 0.50, qPeak: 30),
                (ned: 0.05, fi: 0.50, qPeak: 30),
                (ned: 0.30, fi: 0.50, qPeak: 30),
                (ned: 0.05, fi: 0.50, qPeak: 30),
                (ned: 0.30, fi: 0.50, qPeak: 30),
            ]
        )
        XCTAssertEqual(NEDAnalysis.detectRERAs(per: per).count, 0)
    }

    func testFIAloneCanMarkABreathFlowLimited() {
        // High FI but low NED — common shape for top-hat breaths.
        // Still a FL run; slope is ~0 and there's no recovery /
        // sigh, but maxNED is also low — so all three acceptance
        // criteria fail and no event fires. Confirms the FI-only
        // FL marker doesn't false-fire on its own.
        let per = makePerBreathMetrics(
            specs: [
                (ned: 0.05, fi: 0.50, qPeak: 30),
                (ned: 0.05, fi: 0.90, qPeak: 30),
                (ned: 0.05, fi: 0.90, qPeak: 30),
                (ned: 0.05, fi: 0.90, qPeak: 30),
                (ned: 0.05, fi: 0.90, qPeak: 30),
                (ned: 0.05, fi: 0.50, qPeak: 30),
            ]
        )
        XCTAssertEqual(NEDAnalysis.detectRERAs(per: per).count, 0)
    }

    func testRunExtendingToLastBreathStillFiresOnSustainedNED() {
        // Tail run with no recovery / sigh possible (no breath
        // after the run). Slope is flat. maxNED clears the
        // sustained threshold so the sustained path accepts.
        // AirwayLab handles this end-of-recording case the same way.
        let per = makePerBreathMetrics(
            specs: [
                (ned: 0.05, fi: 0.50, qPeak: 30),
                (ned: 0.40, fi: 0.60, qPeak: 30),
                (ned: 0.40, fi: 0.60, qPeak: 30),
                (ned: 0.40, fi: 0.60, qPeak: 30),
            ]
        )
        let events = NEDAnalysis.detectRERAs(per: per)
        XCTAssertEqual(events.count, 1)
        if let event = events.first {
            XCTAssertFalse(event.hasRecovery)
            XCTAssertFalse(event.hasSigh)
            XCTAssertGreaterThan(event.maxNED, NEDAnalysis.reraSustainedMaxNEDThreshold)
        }
    }

    // MARK: - Accumulator + serialisation

    func testBreakdownAccumulatorMatchesSinglePass() {
        // Two identical halves of sinusoidal flow. Accumulator-
        // averaged breakdown should equal each half's breakdown
        // and stay within sub-sample noise of the concatenated
        // single pass.
        let halfA = (0..<(60 * Int(BreathDetector.sampleRateHz))).map { i in
            25.0 * sin(2 * .pi * Double(i) / 75.0)
        }
        let halfB = halfA
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
        XCTAssertEqual(merged.nedMean, a.breakdown.nedMean, accuracy: 0.01)
        XCTAssertEqual(merged.flatBreathFraction, a.breakdown.flatBreathFraction, accuracy: 0.01)
        XCTAssertEqual(merged.mShapeFraction, a.breakdown.mShapeFraction, accuracy: 0.01)
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

    /// One ~4.5-second top-hat breath cycle. Short ramps (0.16s
    /// each) on purpose so the plateau dominates the inspiration
    /// and FI = mean / peak lands close to 1.
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
        for i in 0..<expirationSamples {
            let phase = Double(i) / Double(expirationSamples)
            out.append(-25 * sin(.pi * phase))
        }
        return out
    }

    /// One ~4-second sawtooth breath cycle. Peak +30 at 0.3s,
    /// linear decay to +5 over 1.5s, then expiration mirrors the
    /// plateau cycle's tail.
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

    /// Build a `BreathMetrics` array straight from `(ned, fi, qPeak)`
    /// tuples. Sidesteps having to back-construct a flow signal
    /// that produces each test's per-breath metric profile — the
    /// RERA detector takes `BreathMetrics` directly, and that's
    /// the only thing being exercised by these tests.
    private func makePerBreathMetrics(
        specs: [(ned: Double, fi: Double, qPeak: Double)]
    ) -> [NEDAnalysis.BreathMetrics] {
        specs.enumerated().map { idx, spec in
            NEDAnalysis.BreathMetrics(
                ned: spec.ned,
                fi: spec.fi,
                isMShape: false,
                qPeak: spec.qPeak,
                sampleIndex: idx * 100
            )
        }
    }
}
