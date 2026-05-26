import Foundation

/// Shared inspiration extractor for breath-by-breath flow analytics.
///
/// Snorecard's per-breath detectors (Glasgow Index, NED Analysis,
/// anything else that lands later) all need the same first pass:
/// take a 25 Hz flow signal in L/min, find the expiration troughs,
/// then sweep each inspiration's start / midpoint / peak / end so
/// downstream code can score it. That pass is non-trivial — local
/// minima with a grey-zone, multi-peak detection, the 10%-of-peak
/// shoulder, the midline-symmetry split — and we don't want two
/// copies drifting apart, nor do we want to decode the BRP file
/// twice when both detectors run on the same night.
///
/// The detection logic is adapted from DaveSkvn's open-source
/// Glasgow Index project (https://github.com/DaveSkvn/GlasgowIndex,
/// GPLv3). The per-breath shape metrics (`leftPercent`,
/// `top90Percent`, `midVariance`, `multiPeak`) are computed here so
/// downstream detectors that re-use any of them (NED's M-shape via
/// `multiPeak`, for instance) don't have to re-walk every sample.
public enum BreathDetector {

    /// One detected inspiration. Indices reference the input
    /// `flowLPerMin` array. `maxValue` is the peak flow in the
    /// caller's units (L/min for our BRP signal). The four shape
    /// fields populate inline during detection — detectors that
    /// don't need them can ignore them at no cost.
    public struct Inspiration: Sendable, Hashable {
        public let start: Int
        public let end: Int
        public let midPoint: Int
        public let maxValue: Double
        public let leftPercent: Double
        public let top90Percent: Double
        public let midVariance: Double
        public let multiPeak: Bool

        public init(
            start: Int,
            end: Int,
            midPoint: Int,
            maxValue: Double,
            leftPercent: Double,
            top90Percent: Double,
            midVariance: Double,
            multiPeak: Bool
        ) {
            self.start = start
            self.end = end
            self.midPoint = midPoint
            self.maxValue = maxValue
            self.leftPercent = leftPercent
            self.top90Percent = top90Percent
            self.midVariance = midVariance
            self.multiPeak = multiPeak
        }
    }

    /// BRP flow is sampled at 25 Hz on every ResMed firmware
    /// Snorecard supports. Detectors keep this as a typed constant
    /// rather than re-deriving it from the EDF header in hot loops.
    public static let sampleRateHz: Double = 25

    /// 1 s window at 25 Hz. The minima sweep and the
    /// "need-at-least-this-much-signal-to-bother" check both
    /// reference it.
    public static let minWindow = 25

    // MARK: - Constants (matching the JS Glasgow reference)
    //
    // Lifted unchanged from the original Glasgow port — the
    // detection behaviour is exactly that algorithm.

    static let greyZoneLower: Double = -10
    static let greyZoneUpper: Double = 5
    static let top90Threshold: Double = 0.9
    static let minPeakBump: Double = 1

    /// Detect every inspiration in a flow signal. Returns nil when
    /// the input is too short for the windowed minima sweep to
    /// produce anything useful — callers treat that as "no data for
    /// this session" and move on.
    public static func inspirations(flowLPerMin: [Double]) -> [Inspiration]? {
        guard flowLPerMin.count > minWindow * 4 else { return nil }

        var samples = flowLPerMin.enumerated().map {
            Sample(index: $0.offset, y: $0.element)
        }
        markMins(&samples)
        let raw = findInspirations(samples)
        return raw
    }

    /// Return the sample indices of the expiration minima detected
    /// by the same windowed sweep `inspirations(_:)` uses. Exposed
    /// so cycle-based scoring passes (e.g. Glasgow's pause
    /// detection) can pair expirations to inspirations without
    /// re-running the sweep.
    public static func expirationMinima(flowLPerMin: [Double]) -> [Int] {
        guard flowLPerMin.count > minWindow * 4 else { return [] }
        var samples = flowLPerMin.enumerated().map {
            Sample(index: $0.offset, y: $0.element)
        }
        markMins(&samples)
        return samples.enumerated().compactMap { $0.element.isMin ? $0.offset : nil }
    }

    // MARK: - Internal sample carrier

    struct Sample {
        let index: Int
        var y: Double
        var isMin = false
    }

    // MARK: - Step 1: Find expiration peaks (local minima)

    static func markMins(_ samples: inout [Sample]) {
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

    // MARK: - Step 2: Detect inspirations and compute shape metrics

    static func findInspirations(_ samples: [Sample]) -> [Inspiration] {
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

            // Mid-50% variance (flat-top detection input)
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

            inspirations.append(
                Inspiration(
                    start: s,
                    end: e,
                    midPoint: midPoint,
                    maxValue: maxValue,
                    leftPercent: leftPercent,
                    top90Percent: top90Percent,
                    midVariance: midVariance,
                    multiPeak: isMultiPeak
                )
            )
            ignoreUntil = e
        }
        return inspirations
    }
}
