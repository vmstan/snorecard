import Foundation

/// Swift port of the Glasgow Index breath-quality score.
///
/// Analyses the raw Flow signal from BRP EDF files (25 Hz, L/min) and
/// scores each inspiration on 9 characteristics.  The overall index is
/// the sum of the 9 sub-indices (each 0–1).  Lower is better.
///
/// Algorithm by DaveSkvn — https://github.com/DaveSkvn/GlasgowIndex
/// Original code licensed under GPLv3.
///
/// The per-breath detection pass — windowed minima sweep + breath
/// segmentation + shape metrics — lives in `BreathDetector` so
/// other detectors (e.g. `NEDAnalysis`) can re-use it without
/// re-decoding the BRP file.
public enum GlasgowIndex {

    /// Per-sub-index fractions that sum to the overall Glasgow
    /// Index. Each field is in 0–1 and represents the fraction of
    /// analysed breaths that triggered that sub-index's criterion
    /// (e.g. `flatTop = 0.42` means 42% of breaths had a flat peak).
    /// The 9 fields added together equal the overall score.
    public struct Breakdown: Codable, Hashable, Sendable {
        public let skew: Double
        public let topHeavy: Double
        public let flatTop: Double
        public let spike: Double
        public let multiPeak: Double
        public let noPause: Double
        public let inspirRate: Double
        public let multiBreath: Double
        public let ampVar: Double

        public init(
            skew: Double,
            topHeavy: Double,
            flatTop: Double,
            spike: Double,
            multiPeak: Double,
            noPause: Double,
            inspirRate: Double,
            multiBreath: Double,
            ampVar: Double
        ) {
            self.skew = skew
            self.topHeavy = topHeavy
            self.flatTop = flatTop
            self.spike = spike
            self.multiPeak = multiPeak
            self.noPause = noPause
            self.inspirRate = inspirRate
            self.multiBreath = multiBreath
            self.ampVar = ampVar
        }

        public var total: Double {
            skew + topHeavy + flatTop + spike + multiPeak
                + noPause + inspirRate + multiBreath + ampVar
        }
    }

    /// Compute the overall Glasgow Index from a single Flow signal.
    /// Returns the score, the 9 sub-index breakdown, and the number
    /// of inspirations analysed, or `nil` when the data is too short.
    public static func compute(flowSamples: [Double]) -> (score: Double, breakdown: Breakdown, inspirationCount: Int)? {
        guard let raw = BreathDetector.inspirations(flowLPerMin: flowSamples) else { return nil }
        guard raw.count >= ampWindowLen + 1 else { return nil }

        // Project the shared detection result into Glasgow's
        // internal record, which adds the cycle / amplitude scratch
        // fields the next two passes populate.
        var inspirations = raw.map { Inspiration(detected: $0) }
        let minIndices = BreathDetector.expirationMinima(flowLPerMin: flowSamples)
        calcCycleBasedIndicators(samples: flowSamples, minIndices: minIndices, inspirations: &inspirations)
        calcAmplitudeVariance(inspirations: &inspirations)

        let breakdown = subIndices(inspirations: inspirations)
        return (breakdown.total, breakdown, inspirations.count)
    }

    /// Compute the Glasgow Index for a full day of BRP sessions.
    /// Each file is scored independently; the results are
    /// weighted-averaged by inspiration count.
    public static func computeDay(brpFiles: [ResMedDataFile]) -> (score: Double, breakdown: Breakdown)? {
        var totalScore: Double = 0
        var weightedSums = BreakdownAccumulator()
        var totalInspirations = 0

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

            guard let result = compute(flowSamples: flowLPerMin) else { continue }
            let weight = Double(result.inspirationCount)
            totalScore += result.score * weight
            weightedSums.add(result.breakdown, weight: weight)
            totalInspirations += result.inspirationCount
        }

        guard totalInspirations > 0 else { return nil }
        let n = Double(totalInspirations)
        return (totalScore / n, weightedSums.finalize(totalWeight: n))
    }

    /// One wall-clock-hour slice of a single BRP session's flow
    /// signal, scored independently. Multiple slices that fall in
    /// the same hour (across overlapping or sequential sessions)
    /// are weighted-averaged by `inspirationCount` to produce the
    /// hour's final score — same weighting `computeDay` uses for
    /// the night-wide aggregate.
    public struct HourSlice: Sendable, Hashable {
        public let hourStart: Date
        public let score: Double
        public let inspirationCount: Int

        public init(hourStart: Date, score: Double, inspirationCount: Int) {
            self.hourStart = hourStart
            self.score = score
            self.inspirationCount = inspirationCount
        }
    }

    /// Slice a single session's flow samples into wall-clock-hour
    /// chunks and score each chunk via `compute`. Hours with too
    /// few inspirations to score are silently dropped (the chart
    /// renders a gap there). Caller weighted-averages across
    /// sessions in the same hour using `inspirationCount`.
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
            // Clamp to the sample range and ensure forward progress
            // even on the rare degenerate slice (tiny last partial
            // hour) where the rounded boundary sits at `i`.
            let endSample = min(count, max(i + 1, Int(endSampleD.rounded(.down))))
            let chunk = Array(flowLPerMin[i..<endSample])
            if let r = compute(flowSamples: chunk) {
                out.append(HourSlice(
                    hourStart: hourStart,
                    score: r.score,
                    inspirationCount: r.inspirationCount
                ))
            }
            i = endSample
        }
        return out
    }

    /// Mutable accumulator for weighted-averaging breakdowns across
    /// multiple BRP files. Exposed publicly so the `DailyStatistics`
    /// aggregate pass can reuse the same weighting logic the
    /// stand-alone `computeDay` path uses.
    public struct BreakdownAccumulator {
        var skew: Double = 0
        var topHeavy: Double = 0
        var flatTop: Double = 0
        var spike: Double = 0
        var multiPeak: Double = 0
        var noPause: Double = 0
        var inspirRate: Double = 0
        var multiBreath: Double = 0
        var ampVar: Double = 0

        public init() {}

        public mutating func add(_ b: Breakdown, weight: Double) {
            skew += b.skew * weight
            topHeavy += b.topHeavy * weight
            flatTop += b.flatTop * weight
            spike += b.spike * weight
            multiPeak += b.multiPeak * weight
            noPause += b.noPause * weight
            inspirRate += b.inspirRate * weight
            multiBreath += b.multiBreath * weight
            ampVar += b.ampVar * weight
        }

        public func finalize(totalWeight: Double) -> Breakdown {
            Breakdown(
                skew: skew / totalWeight,
                topHeavy: topHeavy / totalWeight,
                flatTop: flatTop / totalWeight,
                spike: spike / totalWeight,
                multiPeak: multiPeak / totalWeight,
                noPause: noPause / totalWeight,
                inspirRate: inspirRate / totalWeight,
                multiBreath: multiBreath / totalWeight,
                ampVar: ampVar / totalWeight
            )
        }
    }

    // MARK: - Constants (Glasgow-specific)

    private static let ampWindowLen = 5
    private static let extrapolationSamples = 25  // 1 s lookahead

    // MARK: - Internal record (extends BreathDetector.Inspiration)

    private struct Inspiration {
        let start: Int
        let end: Int
        let maxValue: Double
        let midPoint: Int

        let leftPercent: Double
        let top90Percent: Double
        let midVariance: Double
        let multiPeak: Bool

        // Cycle-based (populated by calcCycleBasedIndicators)
        var noExhale = false
        var preRest: Double = 0

        // Amplitude (populated by calcAmplitudeVariance)
        var ampVariance: Double = 0
        var inspirPerMin: Double = 0

        init(detected: BreathDetector.Inspiration) {
            self.start = detected.start
            self.end = detected.end
            self.maxValue = detected.maxValue
            self.midPoint = detected.midPoint
            self.leftPercent = detected.leftPercent
            self.top90Percent = detected.top90Percent
            self.midVariance = detected.midVariance
            self.multiPeak = detected.multiPeak
        }
    }

    // MARK: - Step 3: Match expirations to inspirations (pause detection)

    private static func calcCycleBasedIndicators(
        samples: [Double],
        minIndices: [Int],
        inspirations: inout [Inspiration]
    ) {
        var nextInspIdx = 0
        let count = samples.count

        for mi in 0..<minIndices.count {
            let minAt = minIndices[mi]
            if nextInspIdx >= inspirations.count { break }

            var safety = 10
            while nextInspIdx < inspirations.count && safety > 0 {
                safety -= 1
                if inspirations[nextInspIdx].start < minAt {
                    inspirations[nextInspIdx].noExhale = true
                    nextInspIdx += 1
                } else if mi < minIndices.count - 1 &&
                          inspirations[nextInspIdx].start > minIndices[mi + 1] {
                    break
                } else if inspirations[nextInspIdx].start > minAt {
                    inspirations[nextInspIdx].noExhale = false

                    let lookAhead = minAt + extrapolationSamples
                    if lookAhead < count {
                        let minValue = samples[minAt]
                        let valuePlus1s = samples[lookAhead]
                        // Extrapolation is only meaningful when the
                        // expiration is still rising toward zero AND
                        // the two samples differ — otherwise the
                        // division would produce infinity / NaN and
                        // crash the Int conversion below.
                        if valuePlus1s < 0, minValue != valuePlus1s {
                            let ratio = Double(extrapolationSamples) * minValue / (minValue - valuePlus1s)
                            if ratio.isFinite {
                                let intersection = minAt + Int(ratio.rounded())
                                inspirations[nextInspIdx].preRest = Double(
                                    inspirations[nextInspIdx].start - intersection
                                )
                            } else {
                                inspirations[nextInspIdx].preRest = -10
                            }
                        } else {
                            inspirations[nextInspIdx].preRest = -10
                        }
                    }
                    nextInspIdx += 1
                    break
                } else {
                    break
                }
            }
        }
    }

    // MARK: - Step 4: Amplitude variance and breathing rate

    private static func calcAmplitudeVariance(inspirations: inout [Inspiration]) {
        for i in ampWindowLen..<inspirations.count {
            var mean: Double = 0
            for c in 0..<ampWindowLen {
                mean += inspirations[i - c].maxValue
            }
            mean /= Double(ampWindowLen)

            var variance: Double = 0
            for c in 0..<ampWindowLen {
                let diff = inspirations[i - c].maxValue - mean
                variance += diff * diff
            }
            inspirations[i].ampVariance = (100 * variance / Double(ampWindowLen)).rounded() / 100

            let sampleSpan = inspirations[i].start - inspirations[i - ampWindowLen].start
            if sampleSpan > 0 {
                // 40 ms per sample — round to integer like the JS does
                inspirations[i].inspirPerMin = (Double(ampWindowLen * 60 * 1000) /
                    (Double(sampleSpan) * 40)).rounded()
            }
        }
    }

    // MARK: - Step 5: Score and produce sub-index breakdown

    private static func subIndices(inspirations: [Inspiration]) -> Breakdown {
        var skew = 0, topHeavy = 0, flatTop = 0, spike = 0
        var multiPeak = 0, noPause = 0, inspirRate = 0
        var multiBreath = 0, ampVar = 0

        for insp in inspirations {
            if insp.leftPercent < 45 || insp.leftPercent > 55 { skew += 1 }
            if insp.top90Percent > 40 { topHeavy += 1 }
            if insp.midVariance < 0.75 { flatTop += 1 }
            if insp.top90Percent < 20 { spike += 1 }
            if insp.multiPeak { multiPeak += 1 }
            if insp.preRest < 10 { noPause += 1 }
            if insp.inspirPerMin > 20 { inspirRate += 1 }
            if insp.noExhale { multiBreath += 1 }
            if insp.ampVariance > 4 { ampVar += 1 }
        }

        let n = Double(inspirations.count)
        return Breakdown(
            skew: Double(skew) / n,
            topHeavy: Double(topHeavy) / n,
            flatTop: Double(flatTop) / n,
            spike: Double(spike) / n,
            multiPeak: Double(multiPeak) / n,
            noPause: Double(noPause) / n,
            inspirRate: Double(inspirRate) / n,
            multiBreath: Double(multiBreath) / n,
            ampVar: Double(ampVar) / n
        )
    }
}
