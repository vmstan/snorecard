import Foundation

/// Swift port of the Glasgow Index breath-quality score.
///
/// Analyses the raw Flow signal from BRP EDF files (25 Hz, L/min) and
/// scores each inspiration on 9 characteristics.  The overall index is
/// the sum of the 9 sub-indices (each 0–1).  Lower is better.
///
/// Algorithm by DaveSkvn — https://github.com/DaveSkvn/GlasgowIndex
/// Original code licensed under GPLv3.
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
        guard flowSamples.count > minWindow * 4 else { return nil }

        var samples = flowSamples.enumerated().map {
            Sample(index: $0.offset, y: $0.element)
        }
        markMins(&samples)

        var inspirations = findInspirations(samples)
        guard inspirations.count >= ampWindowLen + 1 else { return nil }

        calcCycleBasedIndicators(samples: samples, inspirations: &inspirations)
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

    // MARK: - Constants (matching the JS reference)

    private static let minWindow = 25            // 1 s at 25 Hz
    private static let greyZoneLower: Double = -10
    private static let greyZoneUpper: Double = 5
    private static let top90Threshold: Double = 0.9
    private static let ampWindowLen = 5
    private static let extrapolationSamples = 25  // 1 s lookahead
    private static let minPeakBump: Double = 1

    // MARK: - Internal types

    private struct Sample {
        let index: Int
        var y: Double
        var isMin = false
    }

    private struct Inspiration {
        var start: Int
        var end: Int
        var maxValue: Double
        var midPoint: Int

        var leftPercent: Double = 50
        var top90Percent: Double = 32
        var midVariance: Double = 0
        var multiPeak = false

        // Cycle-based
        var noExhale = false
        var preRest: Double = 0

        // Amplitude
        var ampVariance: Double = 0
        var inspirPerMin: Double = 0
    }

    // MARK: - Step 1: Find expiration peaks (local minima)

    private static func markMins(_ samples: inout [Sample]) {
        let count = samples.count
        for i in 0..<min(minWindow, count) {
            samples[i].isMin = false
        }
        for i in minWindow..<(count - minWindow) {
            var isLocalMin = true
            for j in (i - minWindow)..<(i + minWindow - 1) {
                if samples[j].y < samples[i].y {
                    isLocalMin = false
                    break
                }
            }
            samples[i].isMin = isLocalMin && samples[i].y < greyZoneLower
        }
        for i in max(0, count - minWindow - 1)..<count {
            samples[i].isMin = false
        }
    }

    // MARK: - Step 2: Detect inspirations and compute per-breath metrics

    private static func findInspirations(_ samples: [Sample]) -> [Inspiration] {
        var inspirations: [Inspiration] = []
        var ignoreUntil = 0
        let count = samples.count

        for i in 0..<(count - 1) {
            if i < ignoreUntil { continue }
            if samples[i].y <= greyZoneUpper { continue }
            if i == 0 || i == count - 1 { continue }
            // Must be a local max (not rising on either side)
            if samples[i - 1].y > samples[i].y || samples[i].y < samples[i + 1].y {
                continue
            }

            // Walk backward to find start (where flow crosses grey zone)
            var start: Int?
            for d in stride(from: i, through: 1, by: -1) {
                if samples[d].y > samples[i].y { break }
                if samples[d].y <= greyZoneUpper {
                    start = d
                    break
                }
            }
            guard let s = start else { continue }

            // Walk forward to find end
            var end: Int?
            for u in i..<count {
                if samples[u].y > samples[i].y { break }
                if samples[u].y <= greyZoneUpper {
                    end = u
                    break
                }
            }
            guard let e = end else { continue }

            // Ignore very short inspirations (<0.32 s)
            guard e - s >= 8 else { continue }

            let midPoint = s + Int((Double(e - s) / 2).rounded())
            let maxValue = samples[i].y
            let threshold90 = maxValue * top90Threshold

            // Compute skew, top-heavy, flat-top, multi-peak
            var leftVol: Double = 0
            var rightVol: Double = 0
            var top90Count = 0

            var firstPeakFound = false
            var lookingForNext = false
            var lastMax: Double = 0
            var lowestPost: Double = 0
            var isMultiPeak = false

            for p in s..<e {
                let val = samples[p].y
                if p < midPoint { leftVol += val }
                else if p > midPoint { rightVol += val }
                if val > threshold90 { top90Count += 1 }

                // Multi-peak detection
                if !firstPeakFound {
                    if val > lastMax { lastMax = val }
                    else if val < lastMax { firstPeakFound = true }
                } else if !lookingForNext && (lastMax - val) > minPeakBump {
                    lookingForNext = true
                    lowestPost = val
                }
                if lookingForNext && !isMultiPeak {
                    if val < lowestPost { lowestPost = val }
                    else if val > lowestPost + minPeakBump { isMultiPeak = true }
                }
            }

            let span = Double(e - s)
            let leftPercent: Double
            let top90Percent: Double
            if e - s > 12 {
                let total = leftVol + rightVol
                leftPercent = total > 0
                    ? (10000 * leftVol / total).rounded() / 100
                    : 50
                top90Percent = (10000 * Double(top90Count) / span).rounded() / 100
            } else {
                leftPercent = 50
                top90Percent = 32
            }

            // Mid-50% variance (flat-top detection)
            let varStart = midPoint - Int((0.25 * span).rounded())
            let varEnd = midPoint + Int((0.25 * span).rounded())
            let halfSpan = 0.5 * span
            var midSum: Double = 0
            for p in varStart..<varEnd { midSum += samples[p].y }
            let midMean = halfSpan > 0 ? midSum / halfSpan : 0
            var midVar: Double = 0
            for p in varStart..<varEnd {
                midVar += (midMean - samples[p].y) * (midMean - samples[p].y)
            }
            let midVariance = halfSpan > 0
                ? (100 * midVar / halfSpan).rounded() / 100
                : 0

            var insp = Inspiration(
                start: s, end: e, maxValue: maxValue, midPoint: midPoint
            )
            insp.leftPercent = leftPercent
            insp.top90Percent = top90Percent
            insp.midVariance = midVariance
            insp.multiPeak = isMultiPeak
            inspirations.append(insp)
            ignoreUntil = e
        }
        return inspirations
    }

    // MARK: - Step 3: Match expirations to inspirations (pause detection)

    private static func calcCycleBasedIndicators(
        samples: [Sample],
        inspirations: inout [Inspiration]
    ) {
        let minIndices = samples.enumerated().compactMap { $0.element.isMin ? $0.offset : nil }
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
                        let minValue = samples[minAt].y
                        let valuePlus1s = samples[lookAhead].y
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
