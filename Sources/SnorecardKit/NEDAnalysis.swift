import Foundation

/// Per-breath flow-limitation analysis built on top of
/// `BreathDetector`'s inspiration extraction.
///
/// The algorithm tracks AirwayLab's NED engine
/// (https://github.com/airwaylab-app/airwaylab,
/// `lib/analyzers/ned-engine.ts`, GPL-3.0). The detection logic and
/// numeric thresholds are theirs — re-implemented in Swift from the
/// documented behaviour, not translated line-by-line. Snorecard's
/// fraction units (NED ∈ 0..1) differ from AirwayLab's percentage
/// units (NED ∈ 0..100) by a factor of 100; thresholds below are
/// scaled accordingly and each constant cross-references the
/// AirwayLab value it mirrors.
///
/// Per-breath outputs:
///
/// * **NED** (Negative Effort Dependence) — `(Qpeak − Qmid) / Qpeak`,
///   where `Qpeak` is the inspiration's peak flow and `Qmid` is the
///   flow sample at 50% of inspiratory time. Higher values mean the
///   breath peaked early and dragged down through the middle.
/// * **Flatness Index (FI)** — mean inspiratory flow divided by
///   peak inspiratory flow. FI ≥ 0.85 marks a clearly flow-limited
///   breath (Hosselet/Tamisier formulation).
/// * **M-shape** — true when there's a valley below 80% of `Qpeak`
///   in the middle 50% of inspiratory time, with peaks above the
///   same 80% threshold on either side. Targets the bimodal
///   inspiration shape associated with upper-airway oscillation.
///
/// Sequence output:
///
/// * **RERA** — a run of 3-15 consecutive flow-limited breaths
///   (NED > 0.20 OR FI ≥ 0.85), accepted as one event when any of
///   three criteria holds: linear-regression NED slope across the
///   run > 0.005 / breath; OR the following breath is both a
///   recovery (NED < 0.10) and a sigh (Qpeak > 1.5× sequence mean);
///   OR the run's max NED is > 0.34. Multiple disjunctive criteria
///   match the AASM tradition: rising effort, an obvious recovery,
///   or sustained severity all qualify.
///
/// Reported as events per hour at the `DailyStatistics` level.
/// Informational, not a clinical diagnostic.
public enum NEDAnalysis {

    // MARK: - Breakdown

    /// Population-level summary of one session's (or one day's)
    /// breaths. `analysedBreaths` is carried so day-aggregate code
    /// can weight per-session breakdowns by the actual breath
    /// count.
    public struct Breakdown: Codable, Hashable, Sendable {
        public let nedMean: Double             // mean per-breath NED (0..1)
        public let ned95: Double               // 95th-percentile per-breath NED (0..1)
        public let flatBreathFraction: Double  // share of breaths with FI ≥ 0.85
        public let mShapeFraction: Double      // share of breaths flagged M-shape
        public let analysedBreaths: Int

        public init(
            nedMean: Double,
            ned95: Double,
            flatBreathFraction: Double,
            mShapeFraction: Double,
            analysedBreaths: Int
        ) {
            self.nedMean = nedMean
            self.ned95 = ned95
            self.flatBreathFraction = flatBreathFraction
            self.mShapeFraction = mShapeFraction
            self.analysedBreaths = analysedBreaths
        }
    }

    /// One detected RERA event — a run of consecutive flow-limited
    /// breaths that cleared at least one acceptance criterion.
    /// Carries enough context for the day-view chart to bucket
    /// events into wall-clock hours plus enough for debugging /
    /// future visualisation (slope, max NED, recovery / sigh
    /// flags).
    public struct RERAEvent: Sendable, Hashable {
        /// Sample index where the FL run begins. Used for hourly
        /// bucketing — converted to wall-clock via
        /// `sessionStart + index / sampleRate`.
        public let startSampleIndex: Int
        /// Breaths in the FL run (3..15 by construction).
        public let breathCount: Int
        /// Linear-regression slope of NED across the run, per
        /// breath. AirwayLab's units are NED-percentage / breath;
        /// Snorecard's are NED-fraction / breath, so the numerical
        /// value is 1/100th of AirwayLab's.
        public let nedSlope: Double
        /// Largest single-breath NED inside the run.
        public let maxNED: Double
        /// True when the breath after the run has NED < 0.10.
        public let hasRecovery: Bool
        /// True when the breath after the run has `Qpeak > 1.5×`
        /// the run's mean `Qpeak` (a "sigh" breath, often paired
        /// with arousal).
        public let hasSigh: Bool

        public init(
            startSampleIndex: Int,
            breathCount: Int,
            nedSlope: Double,
            maxNED: Double,
            hasRecovery: Bool,
            hasSigh: Bool
        ) {
            self.startSampleIndex = startSampleIndex
            self.breathCount = breathCount
            self.nedSlope = nedSlope
            self.maxNED = maxNED
            self.hasRecovery = hasRecovery
            self.hasSigh = hasSigh
        }
    }

    // MARK: - Hourly slice

    /// One wall-clock-hour slice of a single BRP session. The Day
    /// view's by-hour charts read this directly: `RERAHourlyChart`
    /// uses `reraEvents` + `hourSeconds`, and a future NED-by-hour
    /// chart could plot `ned95` for the same x-axis.
    public struct HourSlice: Sendable, Hashable {
        public let hourStart: Date
        public let nedMean: Double
        public let ned95: Double
        public let flatBreathFraction: Double
        public let mShapeFraction: Double
        public let analysedBreaths: Int
        public let reraEvents: Int
        public let hourSeconds: Double  // partial-hour denominator

        public init(
            hourStart: Date,
            nedMean: Double,
            ned95: Double,
            flatBreathFraction: Double,
            mShapeFraction: Double,
            analysedBreaths: Int,
            reraEvents: Int,
            hourSeconds: Double
        ) {
            self.hourStart = hourStart
            self.nedMean = nedMean
            self.ned95 = ned95
            self.flatBreathFraction = flatBreathFraction
            self.mShapeFraction = mShapeFraction
            self.analysedBreaths = analysedBreaths
            self.reraEvents = reraEvents
            self.hourSeconds = hourSeconds
        }
    }

    // MARK: - Per-breath metric carrier

    /// Per-breath outputs. Kept internal because callers only need
    /// the `Breakdown` and `RERAEvent` summaries — exposing the raw
    /// per-breath array would balloon sidecar size. `qPeak` is
    /// retained on the per-breath record so the RERA pass can check
    /// for sigh breaths (Qpeak spike vs sequence mean).
    struct BreathMetrics: Sendable {
        let ned: Double
        let fi: Double
        let isMShape: Bool
        let qPeak: Double
        /// Start-of-inspiration sample index, carried so RERA events
        /// know where in the session each FL run begins.
        let sampleIndex: Int
    }

    /// Inspiration window as detected by `detectInspirations`.
    /// Half-open `[start, end)`. Strictly positive flow inside the
    /// window — same shape AirwayLab's zero-crossing detector
    /// produces.
    struct Inspiration: Sendable {
        let start: Int
        let end: Int
    }

    /// Minimum inspiration length in samples. AirwayLab uses 10
    /// samples (`minInspSamples`). At 25 Hz that's 0.4 s — below
    /// the shortest plausible adult inspiration.
    static let minInspirationSamples = 10

    /// Minimum peak flow for a candidate to count. AirwayLab uses
    /// 0.1 L/min (`minQPeak`); we use the same in L/min.
    static let minQpeak: Double = 0.1

    // MARK: - Per-breath FL and RERA acceptance thresholds
    //
    // Each constant cross-references the AirwayLab value it mirrors
    // (AirwayLab works in percentage units; we work in fraction
    // units, so most values are 1/100 of theirs).

    /// FI cutoff for flagging a breath as flow-limited. AirwayLab:
    /// `fi >= 0.85`. Snorecard: identical (FI is a ratio, no unit
    /// conversion needed).
    static let flatBreathFIThreshold: Double = 0.85

    /// NED cutoff for flagging a breath as flow-limited. AirwayLab:
    /// `ned > 20` (percent). Snorecard: > 0.20 (fraction).
    static let flowLimitedNEDThreshold: Double = 0.20

    /// Minimum / maximum breaths in a candidate FL run.
    /// AirwayLab: 3..15. Snorecard: identical.
    static let reraRunMinBreaths = 3
    static let reraRunMaxBreaths = 15

    /// NED-slope acceptance threshold. AirwayLab: slope > 0.5
    /// (per breath, percentage units). Snorecard: > 0.005
    /// (per breath, fraction units) — same numerical curve.
    static let reraSlopeThreshold: Double = 0.005

    /// Recovery threshold for the breath following a run.
    /// AirwayLab: `ned < 10` (percent). Snorecard: < 0.10 (fraction).
    static let reraRecoveryNEDThreshold: Double = 0.10

    /// Qpeak ratio for the following breath to count as a sigh.
    /// AirwayLab: `qPeak > 1.5 × meanRunQpeak`. Snorecard: identical
    /// (ratio, no unit conversion).
    static let reraSighQpeakRatio: Double = 1.5

    /// Sustained-NED acceptance threshold. AirwayLab: `maxNED > 34`
    /// (percent). Snorecard: > 0.34 (fraction).
    static let reraSustainedMaxNEDThreshold: Double = 0.34

    // MARK: - Per-session compute

    /// Run NED + FI + M-shape over every inspiration, then scan the
    /// resulting per-breath series for RERA events.
    ///
    /// Mirrors `GlasgowIndex.compute`'s tuple shape so the same BRP
    /// loop in `DailyStatistics.aggregate` can call both detectors
    /// inside one iteration.
    public static func compute(
        flowLPerMin: [Double],
        sampleRate: Double = BreathDetector.sampleRateHz,
        sessionStart: Date = Date()
    ) -> (
        breakdown: Breakdown,
        reraEvents: [RERAEvent],
        durationSeconds: Double
    )? {
        _ = sessionStart  // reserved; computeHourly threads it through
        let inspirations = detectInspirations(flow: flowLPerMin)
        guard inspirations.count >= reraRunMinBreaths * 2 else { return nil }

        let per = inspirations.compactMap {
            perBreathMetrics(samples: flowLPerMin, inspiration: $0)
        }
        guard !per.isEmpty else { return nil }
        let breakdown = makeBreakdown(per: per)
        let reras = detectRERAs(per: per)
        let durationSeconds = sampleRate > 0
            ? Double(flowLPerMin.count) / sampleRate
            : 0
        return (breakdown, reras, durationSeconds)
    }

    /// Whole-day pass for callers that don't already have the BRP
    /// data decoded. `DailyStatistics.aggregate` does its own
    /// per-session loop alongside Glasgow so it can share the
    /// already-decoded flow array; this entry point exists for
    /// tests and stand-alone callers.
    public static func computeDay(brpFiles: [ResMedDataFile]) -> (
        breakdown: Breakdown,
        reraIndex: Double,
        totalEvents: Int
    )? {
        var accumulator = BreakdownAccumulator()
        var totalAnalysedBreaths = 0
        var totalEvents = 0
        var totalDurationSeconds: Double = 0

        for file in brpFiles {
            guard let edf = try? EDFFile(contentsOf: file.url),
                  edf.header.recordCount > 0,
                  let idx = edf.signals.firstIndex(where: { $0.label.hasPrefix("Flow") }),
                  let decoded = try? edf.physicalSamples(ofSignal: idx)
            else { continue }

            let unit = edf.signals[idx].physicalDimension
                .trimmingCharacters(in: .whitespaces).lowercased()
            let scale: Double = unit.contains("l/s") ? 60 : 1
            let flowLPerMin = decoded.map { $0 * scale }

            let sampleRate = Double(edf.signals[idx].samplesPerRecord) / edf.header.recordDuration
            guard let result = compute(
                flowLPerMin: flowLPerMin,
                sampleRate: sampleRate,
                sessionStart: file.timestamp ?? Date()
            ) else { continue }
            let weight = Double(result.breakdown.analysedBreaths)
            accumulator.add(result.breakdown, weight: weight)
            totalAnalysedBreaths += result.breakdown.analysedBreaths
            totalEvents += result.reraEvents.count
            totalDurationSeconds += result.durationSeconds
        }

        guard totalAnalysedBreaths > 0, totalDurationSeconds > 0 else { return nil }
        let breakdown = accumulator.finalize(
            totalWeight: Double(totalAnalysedBreaths),
            analysedBreaths: totalAnalysedBreaths
        )
        let reraIndex = Double(totalEvents) / (totalDurationSeconds / 3600.0)
        return (breakdown, reraIndex, totalEvents)
    }

    /// Slice one session into wall-clock-hour chunks the same way
    /// `GlasgowIndex.computeHourly` does. Hours too short to produce
    /// a breakdown are silently dropped (the chart leaves a gap).
    public static func computeHourly(
        flowLPerMin: [Double],
        sampleRate: Double,
        sessionStart: Date,
        calendar: Calendar = .current
    ) -> [HourSlice] {
        guard sampleRate > 0, !flowLPerMin.isEmpty else { return [] }

        var out: [HourSlice] = []
        var i = 0
        let count = flowLPerMin.count

        while i < count {
            let sampleTime = sessionStart.addingTimeInterval(Double(i) / sampleRate)
            guard let hourStart = calendar.dateInterval(of: .hour, for: sampleTime)?.start else {
                i += 1
                continue
            }
            let nextHour = hourStart.addingTimeInterval(3600)
            let endSampleD = nextHour.timeIntervalSince(sessionStart) * sampleRate
            let endSample = min(count, max(i + 1, Int(endSampleD.rounded(.down))))
            let chunk = Array(flowLPerMin[i..<endSample])
            if let r = compute(
                flowLPerMin: chunk,
                sampleRate: sampleRate,
                sessionStart: sessionStart.addingTimeInterval(Double(i) / sampleRate)
            ) {
                let hourSeconds = Double(endSample - i) / sampleRate
                out.append(HourSlice(
                    hourStart: hourStart,
                    nedMean: r.breakdown.nedMean,
                    ned95: r.breakdown.ned95,
                    flatBreathFraction: r.breakdown.flatBreathFraction,
                    mShapeFraction: r.breakdown.mShapeFraction,
                    analysedBreaths: r.breakdown.analysedBreaths,
                    reraEvents: r.reraEvents.count,
                    hourSeconds: hourSeconds
                ))
            }
            i = endSample
        }
        return out
    }

    // MARK: - Accumulator for weighted-averaging across sessions

    public struct BreakdownAccumulator {
        var nedMean: Double = 0
        var ned95: Double = 0
        var flatBreathFraction: Double = 0
        var mShapeFraction: Double = 0

        public init() {}

        public mutating func add(_ b: Breakdown, weight: Double) {
            nedMean += b.nedMean * weight
            ned95 += b.ned95 * weight
            flatBreathFraction += b.flatBreathFraction * weight
            mShapeFraction += b.mShapeFraction * weight
        }

        public func finalize(totalWeight: Double, analysedBreaths: Int) -> Breakdown {
            guard totalWeight > 0 else {
                return Breakdown(
                    nedMean: 0, ned95: 0,
                    flatBreathFraction: 0, mShapeFraction: 0,
                    analysedBreaths: 0
                )
            }
            return Breakdown(
                nedMean: nedMean / totalWeight,
                ned95: ned95 / totalWeight,
                flatBreathFraction: flatBreathFraction / totalWeight,
                mShapeFraction: mShapeFraction / totalWeight,
                analysedBreaths: analysedBreaths
            )
        }
    }

    // MARK: - Breath detection (AirwayLab-style, zero-crossing)
    //
    // Snorecard's other per-breath analysis (Glasgow Index) uses
    // `BreathDetector` — windowed local-minima sweep + grey-zone
    // bracketing. That's tuned for breath-quality scoring on the
    // CPAP flow signal. For flow-limitation analysis we want
    // AirwayLab's interpretation instead: every positive-going
    // zero crossing opens an inspiration, every negative-going
    // zero crossing closes it. No grey zone, no local-max anchor.
    // This keeps the per-breath NED / FI / M-shape numbers in
    // line with AirwayLab's reference engine; mixing the two
    // detectors (theirs for metrics, ours for breath segmentation)
    // is what produced the systematically-low NED Mean / zero FL
    // breaths we saw on real data before this change.

    /// Walk the flow signal looking for positive-going zero
    /// crossings; collect each strictly-positive window as one
    /// inspiration. Mirrors AirwayLab's `detectBreaths`. Windows
    /// shorter than `minInspirationSamples` (10 by default) are
    /// dropped here so the per-breath pass doesn't have to defend
    /// against them.
    static func detectInspirations(flow: [Double]) -> [Inspiration] {
        var out: [Inspiration] = []
        var i = 0
        let len = flow.count
        while i < len - 1 {
            // Positive-going zero crossing: flow[i] <= 0 and
            // flow[i+1] > 0. AirwayLab anchors `inspStart` at the
            // sample *after* the crossing.
            while i < len - 1 && !(flow[i] <= 0 && flow[i + 1] > 0) { i += 1 }
            if i >= len - 1 { break }
            let inspStart = i + 1
            i = inspStart

            // Walk forward while flow stays positive. Stop on the
            // first non-positive sample; that index is the end of
            // the inspiration (half-open, samples[end] is the
            // first non-positive).
            while i < len - 1 && flow[i] > 0 { i += 1 }
            if i >= len - 1 { break }
            let inspEnd = i

            if inspEnd - inspStart >= Self.minInspirationSamples {
                out.append(Inspiration(start: inspStart, end: inspEnd))
            }
        }
        return out
    }

    // MARK: - Per-breath metric computation

    /// Compute NED, FI, and M-shape for one inspiration window.
    /// Returns nil when the window's peak fails the `minQpeak`
    /// gate — same skip AirwayLab applies after `qPeak` is read.
    static func perBreathMetrics(
        samples: [Double],
        inspiration: Inspiration
    ) -> BreathMetrics? {
        let start = inspiration.start
        let end = inspiration.end
        guard end > start else { return nil }

        // Single pass over the window: peak, mean, and the sample
        // at the inspiration's midpoint for NED.
        var qPeak: Double = 0
        var sum: Double = 0
        let len = end - start
        for p in start..<end {
            let v = samples[p]
            if v > qPeak { qPeak = v }
            sum += v
        }
        guard qPeak >= Self.minQpeak else { return nil }

        let midIdx = start + (len / 2)
        let qMid = samples[midIdx]

        // Standard NED ratio. Clamp at 0 so a midpoint sample
        // marginally above the recorded peak (numerical edge case
        // on noisy traces) doesn't go negative.
        let ned = qPeak > 0 ? max(0, (qPeak - qMid) / qPeak) : 0

        // Flatness Index — time-averaged inspiratory flow divided
        // by peak. Every sample in the window is positive by
        // construction (zero-crossing detector), so no positive-
        // only filter is needed here.
        let meanFlow = sum / Double(len)
        let fi = qPeak > 0 ? meanFlow / qPeak : 0

        let isMShape = detectMShape(
            samples: samples,
            start: start,
            end: end,
            qPeak: qPeak
        )

        return BreathMetrics(
            ned: ned,
            fi: fi,
            isMShape: isMShape,
            qPeak: qPeak,
            sampleIndex: start
        )
    }

    /// Explicit M-shape detector: the bi-modal inspiration shape
    /// where flow dips below 80% of `qPeak` somewhere in the
    /// middle 50% of inspiratory time, *and* both halves of the
    /// inspiration touch back above that 80% threshold so the
    /// shape genuinely reads as two humps and not a single late
    /// peak.
    ///
    /// Matches AirwayLab's `detectMShape` shape rather than the
    /// looser `BreathDetector.multiPeak` flag (which fires on any
    /// dip-and-recover pattern anywhere in the breath).
    private static func detectMShape(
        samples: [Double],
        start: Int,
        end: Int,
        qPeak: Double
    ) -> Bool {
        let len = end - start
        guard len >= 12, qPeak > 0 else { return false }

        let threshold = qPeak * 0.8
        let middleStart = start + Int(Double(len) * 0.25)
        let middleEnd = start + Int(Double(len) * 0.75)
        guard middleEnd > middleStart else { return false }

        var minInMiddle = qPeak
        var valleyIdx = middleStart
        for p in middleStart..<middleEnd {
            if samples[p] < minInMiddle {
                minInMiddle = samples[p]
                valleyIdx = p
            }
        }
        guard minInMiddle < threshold else { return false }

        var leftPeak: Double = 0
        for p in start..<valleyIdx {
            if samples[p] > leftPeak { leftPeak = samples[p] }
        }
        var rightPeak: Double = 0
        for p in valleyIdx..<end {
            if samples[p] > rightPeak { rightPeak = samples[p] }
        }
        return leftPeak > threshold && rightPeak > threshold
    }

    // MARK: - Population summary

    static func makeBreakdown(per: [BreathMetrics]) -> Breakdown {
        let n = per.count
        guard n > 0 else {
            return Breakdown(
                nedMean: 0, ned95: 0,
                flatBreathFraction: 0, mShapeFraction: 0,
                analysedBreaths: 0
            )
        }
        let neds = per.map(\.ned)
        let mean = neds.reduce(0, +) / Double(n)
        let p95 = percentile(neds, 95)
        let flat = per.reduce(0) { $0 + ($1.fi >= flatBreathFIThreshold ? 1 : 0) }
        let mShape = per.reduce(0) { $0 + ($1.isMShape ? 1 : 0) }
        return Breakdown(
            nedMean: mean,
            ned95: p95,
            flatBreathFraction: Double(flat) / Double(n),
            mShapeFraction: Double(mShape) / Double(n),
            analysedBreaths: n
        )
    }

    // MARK: - RERA detection

    /// Walk the per-breath series looking for consecutive runs of
    /// flow-limited breaths (NED > 0.20 OR FI ≥ 0.85), then
    /// evaluate each candidate run against three acceptance
    /// criteria: rising NED slope, paired recovery+sigh, or
    /// sustained max NED. Any one is enough.
    ///
    /// Mirrors AirwayLab's `detectRERASequences` / `evaluateRERA`
    /// pair. Internal — exposed only via `compute` / `computeDay` /
    /// `computeHourly`.
    static func detectRERAs(per: [BreathMetrics]) -> [RERAEvent] {
        guard per.count >= reraRunMinBreaths else { return [] }
        var events: [RERAEvent] = []

        func isFL(_ b: BreathMetrics) -> Bool {
            b.ned > Self.flowLimitedNEDThreshold || b.fi >= Self.flatBreathFIThreshold
        }

        var runStart: Int? = nil
        for i in 0..<per.count {
            if isFL(per[i]) {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                if let event = evaluateRun(per: per, start: start, end: i) {
                    events.append(event)
                }
                runStart = nil
            }
        }
        // Tail-handle a run that extends to the last breath. AirwayLab
        // does the same — without it a flow-limited run right at the
        // end of a session never produces an event.
        if let start = runStart {
            if let event = evaluateRun(per: per, start: start, end: per.count) {
                events.append(event)
            }
        }
        return events
    }

    /// Decide whether the half-open `[start, end)` slice qualifies as
    /// a RERA. Run-length filtering happens here, not in the caller,
    /// so the caller doesn't need to know the 3..15 bounds.
    private static func evaluateRun(
        per: [BreathMetrics],
        start: Int,
        end: Int
    ) -> RERAEvent? {
        let breathCount = end - start
        guard breathCount >= reraRunMinBreaths,
              breathCount <= reraRunMaxBreaths else { return nil }

        // Linear-regression slope of NED across the run, per breath.
        // Two-point edge case (breathCount == 2) can't occur because
        // of the `>= reraRunMinBreaths` guard above (min is 3).
        var sumX: Double = 0, sumY: Double = 0
        var sumXY: Double = 0, sumXX: Double = 0
        var meanQpeak: Double = 0
        var maxNED: Double = 0
        for offset in 0..<breathCount {
            let b = per[start + offset]
            let x = Double(offset)
            sumX += x
            sumY += b.ned
            sumXY += x * b.ned
            sumXX += x * x
            meanQpeak += b.qPeak
            if b.ned > maxNED { maxNED = b.ned }
        }
        meanQpeak /= Double(breathCount)
        let n = Double(breathCount)
        let denom = n * sumXX - sumX * sumX
        let nedSlope = denom != 0 ? (n * sumXY - sumX * sumY) / denom : 0

        // Recovery + sigh both consult the breath right after the
        // run. AirwayLab requires `end < per.count` here too —
        // tail-runs (last breath of the session) never have a
        // recovery / sigh signal, so those acceptance paths can't
        // fire and only the slope / maxNED paths remain.
        var hasRecovery = false
        var hasSigh = false
        if end < per.count {
            let next = per[end]
            hasRecovery = next.ned < Self.reraRecoveryNEDThreshold
            hasSigh = next.qPeak > Self.reraSighQpeakRatio * meanQpeak
        }

        let accepted = nedSlope > Self.reraSlopeThreshold
            || (hasRecovery && hasSigh)
            || maxNED > Self.reraSustainedMaxNEDThreshold
        guard accepted else { return nil }

        return RERAEvent(
            startSampleIndex: per[start].sampleIndex,
            breathCount: breathCount,
            nedSlope: nedSlope,
            maxNED: maxNED,
            hasRecovery: hasRecovery,
            hasSigh: hasSigh
        )
    }

    // MARK: - Percentile helper

    /// Linear-interpolated percentile, matching the pattern used by
    /// `DailyStatistics.percentile`. Internal so tests can reach it
    /// for fixture construction.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = (p / 100.0) * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
