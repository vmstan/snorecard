import Foundation

/// Per-breath flow-limitation analysis built on top of
/// `BreathDetector`'s inspiration extraction.
///
/// For every inspiration the detector finds in a 25 Hz flow signal,
/// `NEDAnalysis` computes three shape indicators:
///
/// * **NED** (Negative Effort Dependence) — `(Qpeak − Qmid) / Qpeak`,
///   where `Qpeak` is the inspiration's peak flow and `Qmid` is flow
///   at 50% of inspiratory time. Higher values indicate the
///   inspiration peaks early and decays through the breath — a
///   fingerprint of upper-airway flow limitation. Concept from
///   Tamisier et al.'s CPAP flow-limitation literature.
/// * **Flatness Index (FI)** — fraction of the inspiration's samples
///   sitting within 10% of `Qpeak`. FI ≥ 0.85 marks a clearly
///   flow-limited breath.
/// * **M-shape** — breaths with a characteristic mid-inspiratory dip
///   (oscillation in the flow waveform). Reuses
///   `BreathDetector.Inspiration.multiPeak`, which already detects
///   the same dip-then-rise pattern.
///
/// Once the per-breath series exists, `NEDAnalysis` scans it for
/// **RERA** events — runs of ≥3 breaths whose NED rises
/// progressively, terminated by a recovery breath with a sudden NED
/// drop. RERA detection is adapted from AASM clinical scoring
/// criteria; the specific thresholds are Snorecard's own
/// interpretation and the resulting `reraIndex` (events / hour) is
/// informational, not a clinical diagnostic.
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

    /// One detected RERA event — emitted when a run of ≥3 breaths
    /// of progressively rising NED is terminated by a recovery
    /// breath. Carries the recovery breath's sample index so
    /// callers can bucket events into wall-clock hours.
    public struct RERAEvent: Sendable, Hashable {
        public let recoveryBreathSampleIndex: Int
        public let runLength: Int      // breaths in the rising run (≥ 3)
        public let nedSlope: Double    // mean ΔNED per breath across the run

        public init(recoveryBreathSampleIndex: Int, runLength: Int, nedSlope: Double) {
            self.recoveryBreathSampleIndex = recoveryBreathSampleIndex
            self.runLength = runLength
            self.nedSlope = nedSlope
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
    /// per-breath array would balloon sidecar size.
    struct BreathMetrics: Sendable {
        let ned: Double
        let fi: Double
        let isMShape: Bool
        /// Start-of-inspiration sample index, carried so RERA events
        /// know where in the session the recovery breath sits.
        let sampleIndex: Int
    }

    // MARK: - RERA detection thresholds
    //
    // Snorecard's own interpretation of AASM-style scoring. Kept as
    // typed constants so tests can reference the same names rather
    // than re-spelling the numbers.

    /// Minimum breaths in a rising run before the recovery breath
    /// can close out a RERA event.
    static let reraRunMinBreaths = 3

    /// Minimum per-breath ΔNED to count two consecutive breaths as
    /// part of a rising run.
    static let reraRisePerBreathMin: Double = 0.04

    /// Minimum drop between the last rising breath and the
    /// recovery breath. Pairs with `reraRecoveryAbsMax` — a
    /// recovery breath must drop substantially AND end up
    /// non-flow-limited in absolute terms.
    static let reraRecoveryDropMin: Double = 0.10

    /// Absolute NED ceiling for the recovery breath itself.
    /// Keeps the algorithm from "closing" a run that just paused
    /// briefly mid-event.
    static let reraRecoveryAbsMax: Double = 0.20

    /// How many breaths to skip after firing an event before
    /// looking for another run.
    static let reraCooldownBreaths = 2

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
        _ = sessionStart  // reserved; future per-hour callers feed it through computeHourly
        guard let inspirations = BreathDetector.inspirations(flowLPerMin: flowLPerMin),
              inspirations.count >= 6 else { return nil }

        let per = inspirations.map { perBreathMetrics(samples: flowLPerMin, inspiration: $0) }
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

    // MARK: - Per-breath metric computation

    static func perBreathMetrics(
        samples: [Double],
        inspiration: BreathDetector.Inspiration
    ) -> BreathMetrics {
        let qPeak = inspiration.maxValue
        let qMid = samples[inspiration.midPoint]
        // NED uses the standard ratio; clamp at 0 so a midpoint
        // higher than the recorded peak (rare numerical edge cases
        // near zero crossings) doesn't produce a negative score.
        let ned = qPeak > 0 ? max(0, (qPeak - qMid) / qPeak) : 0

        // FI: fraction of the inspiration that sits within 10% of
        // qPeak. Empirically the simplest plateau measure that
        // tracks the literature's ≥ 0.85 = flow-limited threshold.
        let band = 0.10 * qPeak
        var within = 0
        if inspiration.end > inspiration.start {
            for p in inspiration.start..<inspiration.end {
                if abs(samples[p] - qPeak) <= band { within += 1 }
            }
        }
        let fi = inspiration.end > inspiration.start
            ? Double(within) / Double(inspiration.end - inspiration.start)
            : 0

        return BreathMetrics(
            ned: ned,
            fi: fi,
            isMShape: inspiration.multiPeak,
            sampleIndex: inspiration.start
        )
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
        let flat = per.reduce(0) { $0 + ($1.fi >= 0.85 ? 1 : 0) }
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

    /// Walk the per-breath NED series looking for runs of
    /// progressively rising NED that close out with a recovery
    /// breath. Internal — exposed only via `compute` / `computeDay`
    /// / `computeHourly`.
    static func detectRERAs(per: [BreathMetrics]) -> [RERAEvent] {
        guard per.count >= reraRunMinBreaths + 1 else { return [] }
        var events: [RERAEvent] = []
        var i = 0
        let end = per.count - 1  // need at least one breath after the run for recovery

        while i < end {
            var j = i
            var rises = 0
            var slope: Double = 0
            // Walk forward while every consecutive ΔNED clears the
            // rise threshold. The first breath in the run is per[i];
            // a "rise" is a delta between two consecutive breaths,
            // so `rises` ends up at run_length - 1.
            while j + 1 < per.count, per[j + 1].ned - per[j].ned >= Self.reraRisePerBreathMin {
                slope += per[j + 1].ned - per[j].ned
                rises += 1
                j += 1
            }

            let runLength = rises + 1
            if runLength >= Self.reraRunMinBreaths,
               j + 1 < per.count,
               per[j].ned - per[j + 1].ned >= Self.reraRecoveryDropMin,
               per[j + 1].ned <= Self.reraRecoveryAbsMax {
                events.append(
                    RERAEvent(
                        recoveryBreathSampleIndex: per[j + 1].sampleIndex,
                        runLength: runLength,
                        nedSlope: rises > 0 ? slope / Double(rises) : 0
                    )
                )
                i = j + 1 + Self.reraCooldownBreaths
            } else {
                i += 1
            }
        }
        return events
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
