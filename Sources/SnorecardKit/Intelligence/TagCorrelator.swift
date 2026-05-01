import Foundation

/// Pure-Swift correlation math. Given a set of per-day tag
/// assignments plus the matching `DailyStatistics`, emit only
/// observations that clear a per-metric sample-size and noise
/// floor. The LLM never sees raw means-over-groups math — it only
/// narrates this function's output.
///
/// Minimum thresholds are deliberately conservative. Small samples
/// and personal notes are a noisy combination, and surfacing weak
/// observations would invite misreading.
public enum TagCorrelator {
    /// Per-day input. `tags` is empty for untagged nights.
    public struct DayInput: Sendable {
        public let tags: Set<NoteTag>
        public let stats: DailyStatistics

        public init(tags: Set<NoteTag>, stats: DailyStatistics) {
            self.tags = tags
            self.stats = stats
        }
    }

    /// Noise floors — absolute value of `delta` must exceed this
    /// for the observation to be surfaced. Values picked to match
    /// within-subject night-to-night variability typical of ResMed
    /// data so we don't trip on measurement noise.
    static let noiseFloors: [CorrelatedMetric: Double] = [
        .ahi: 0.8,                // events/hour
        .usageHours: 0.5,         // hours
        .leak95LPerMin: 3.0,      // L/min
        .glasgowIndex: 0.15       // unitless score
    ]

    /// Minimum days-with-data in the range overall. Below this we
    /// don't compute anything — too little signal.
    public static let minimumRangeSize = 10

    /// Minimum nights with AND without the tag, per-tag basis.
    public static let minimumPerGroup = 4

    /// Compute correlation observations for the supplied range.
    /// Returns an empty array when thresholds aren't met so the
    /// caller can hide the card. `excludeCentralFromAHI` mirrors
    /// the user's CA-display preference so tagged-vs-untagged AHI
    /// deltas use the same projection the rest of the app shows.
    public static func correlate(
        days: [DayInput],
        excludeCentralFromAHI: Bool = false
    ) -> [CorrelationNarrativeInput.Observation] {
        guard days.count >= minimumRangeSize else { return [] }

        var observations: [CorrelationNarrativeInput.Observation] = []
        let uniqueTags = Set(days.flatMap { $0.tags })

        for tag in uniqueTags.sorted(by: { $0.rawValue < $1.rawValue }) {
            let tagged = days.filter { $0.tags.contains(tag) }
            let untagged = days.filter { !$0.tags.contains(tag) }
            guard tagged.count >= minimumPerGroup,
                  untagged.count >= minimumPerGroup else { continue }

            for metric in [
                CorrelatedMetric.ahi,
                .usageHours,
                .leak95LPerMin,
                .glasgowIndex
            ] {
                guard let taggedMean = mean(
                    of: metric,
                    days: tagged,
                    excludeCentralFromAHI: excludeCentralFromAHI
                ),
                      let untaggedMean = mean(
                    of: metric,
                    days: untagged,
                    excludeCentralFromAHI: excludeCentralFromAHI
                )
                else { continue }
                let delta = taggedMean - untaggedMean
                let floor = noiseFloors[metric] ?? 0
                guard abs(delta) > floor else { continue }
                observations.append(
                    CorrelationNarrativeInput.Observation(
                        tag: tag,
                        metric: metric,
                        taggedNights: tagged.count,
                        untaggedNights: untagged.count,
                        taggedMean: PromptRounding.round2(taggedMean),
                        untaggedMean: PromptRounding.round2(untaggedMean),
                        delta: PromptRounding.round2(delta)
                    )
                )
            }
        }

        // Strongest-signal-first ordering so the LLM's 3-bullet cap
        // always picks the most prominent observations. Ties are
        // broken by tag name for stability.
        observations.sort { lhs, rhs in
            let lScore = abs(lhs.delta) / (noiseFloors[lhs.metric] ?? 1)
            let rScore = abs(rhs.delta) / (noiseFloors[rhs.metric] ?? 1)
            if lScore != rScore { return lScore > rScore }
            return lhs.tag.rawValue < rhs.tag.rawValue
        }

        return observations
    }

    private static func mean(
        of metric: CorrelatedMetric,
        days: [DayInput],
        excludeCentralFromAHI: Bool
    ) -> Double? {
        let values: [Double] = days.compactMap { day in
            switch metric {
            case .ahi:
                return day.stats.displayedAHI(includingCentral: !excludeCentralFromAHI)
            case .usageHours:       return day.stats.usageHours
            case .leak95LPerMin:    return day.stats.leak95LPerMin
            case .glasgowIndex:     return day.stats.glasgowIndex
            }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
