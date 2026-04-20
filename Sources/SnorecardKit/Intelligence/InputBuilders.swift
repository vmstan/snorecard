import Foundation

/// Pure helpers that shape raw `DailyStatistics` into the canonical,
/// rounded inputs each Intelligence prompt expects. Kept separate
/// from the prompt builders so test fixtures can drive the prompt
/// builders directly without reaching for real statistics.
public enum IntelligenceInputBuilder {

    // MARK: - Night summary

    /// Build a `NightSummaryInput` from the single night's stats, an
    /// optional trailing baseline, and an optional user note. Values
    /// are rounded to the precision declared on `NightSummaryInput`
    /// so float drift doesn't invalidate cached entries.
    public static func nightSummary(
        stats: DailyStatistics,
        baseline: Baseline?,
        userNote: String?
    ) -> NightSummaryInput {
        let usageHours = PromptRounding.round1(stats.usageHours)
        let ahi = PromptRounding.round1(stats.ahi)
        let glasgowIndex = stats.glasgowIndex.map(PromptRounding.round2)
        // `DayDetailView`'s EPAP card renders `epap95` with an
        // optional IPAP subtitle (shown only when IPAP > EPAP),
        // and is hidden entirely when `epap95` is nil. Mirror that
        // exactly so the night summary only mentions pressure when
        // the card is visible and the number the model sees matches
        // the number on screen.
        let pressure95 = stats.epap95.map(PromptRounding.round1)

        let eprSupport: Double? = {
            guard let ipap = stats.ipap95, let epap = stats.epap95 else { return nil }
            return PromptRounding.round1(max(0, ipap - epap))
        }()

        let leak95 = stats.leak95LPerMin.map(PromptRounding.toInt)
        let largeLeakPercent: Double? = {
            guard let seconds = stats.largeLeakSeconds,
                  stats.usageMinutes > 0 else { return nil }
            let raw = seconds / (stats.usageMinutes * 60) * 100
            return PromptRounding.round1(raw)
        }()
        let apneaPercent: Double? = {
            guard let seconds = stats.timeInApneaSeconds,
                  stats.usageMinutes > 0 else { return nil }
            return PromptRounding.round1(seconds / (stats.usageMinutes * 60) * 100)
        }()
        let tidalMedianML = stats.tidalVolume50.map { PromptRounding.toInt($0 * 1000) }

        let diff = baseline.map { baseline -> NightSummaryInput.BaselineDiff in
            NightSummaryInput.BaselineDiff(
                ahiDelta: PromptRounding.round1(stats.ahi - baseline.ahi),
                usageHoursDelta: PromptRounding.round1(stats.usageHours - baseline.usageHours),
                leakDelta: baseline.leak95LPerMin.flatMap { base in
                    stats.leak95LPerMin.map { PromptRounding.round1($0 - base) }
                },
                giDelta: baseline.glasgowIndex.flatMap { base in
                    stats.glasgowIndex.map { PromptRounding.round2($0 - base) }
                }
            )
        }

        // The user's free-form journal is the only unbounded
        // input into the prompt. The on-device model has a 4096-
        // token context window; a long journal entry alone can
        // blow past that and the framework throws
        // `exceededContextWindowSize`. Cap to a generous but
        // bounded prefix so the prompt stays comfortably under
        // the limit. Breaking on a word boundary and appending an
        // ellipsis signals truncation to the model without
        // confusing the narration.
        let trimmedNote: String? = {
            guard let raw = userNote?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            let cap = 400
            guard raw.count > cap else { return raw }
            let prefix = raw.prefix(cap)
            if let lastSpace = prefix.lastIndex(of: " ") {
                return String(prefix[..<lastSpace]) + "…"
            }
            return String(prefix) + "…"
        }()

        return NightSummaryInput(
            date: stats.date,
            usageHours: usageHours,
            ahi: ahi,
            glasgowIndex: glasgowIndex,
            pressure95: pressure95,
            eprSupport: eprSupport,
            leak95LPerMin: leak95,
            largeLeakPercent: largeLeakPercent,
            timeInApneaPercent: apneaPercent,
            tidalVolumeMedianML: tidalMedianML,
            baselineDiff: diff,
            userNote: trimmedNote
        )
    }

    /// Rolling trailing-window baseline the night-summary prompt
    /// compares against. All fields are arithmetic means over
    /// nights-with-usage within the window.
    public struct Baseline: Sendable, Equatable {
        public let ahi: Double
        public let usageHours: Double
        public let leak95LPerMin: Double?
        public let glasgowIndex: Double?

        public init(
            ahi: Double,
            usageHours: Double,
            leak95LPerMin: Double?,
            glasgowIndex: Double?
        ) {
            self.ahi = ahi
            self.usageHours = usageHours
            self.leak95LPerMin = leak95LPerMin
            self.glasgowIndex = glasgowIndex
        }

        /// Compute the trailing-14-day baseline relative to `date`.
        /// Returns `nil` when fewer than 3 days with usage fall
        /// inside the window — too little signal to anchor a diff.
        public static func trailing14(
            before date: Date,
            from stats: [DailyStatistics]
        ) -> Baseline? {
            let calendar = Calendar.current
            guard let windowStart = calendar.date(
                byAdding: .day,
                value: -14,
                to: date
            ) else { return nil }
            let window = stats.filter {
                $0.hasUsage && $0.date >= windowStart && $0.date < date
            }
            guard window.count >= 3 else { return nil }
            let ahi = window.reduce(0) { $0 + $1.ahi } / Double(window.count)
            let usage = window.reduce(0) { $0 + $1.usageHours } / Double(window.count)
            let leaks = window.compactMap(\.leak95LPerMin)
            let leakMean = leaks.isEmpty
                ? nil
                : leaks.reduce(0, +) / Double(leaks.count)
            let gis = window.compactMap(\.glasgowIndex)
            let giMean = gis.isEmpty
                ? nil
                : gis.reduce(0, +) / Double(gis.count)
            return Baseline(
                ahi: ahi,
                usageHours: usage,
                leak95LPerMin: leakMean,
                glasgowIndex: giMean
            )
        }
    }

    // MARK: - Overview narrative

    /// Shape an `OverviewNarrativeInput` from the filtered stats in
    /// a range. `sampleSize` is the count of days with usage; the
    /// model calibrates confidence against that.
    public static func overviewNarrative(
        stats: [DailyStatistics],
        rangeStart: Date,
        rangeEnd: Date
    ) -> OverviewNarrativeInput {
        let days = stats.filter(\.hasUsage)
        let sample = days.count
        let compliantDays = days.filter { $0.usageHours >= 4 }.count
        let compliance = sample == 0
            ? 0
            : Double(compliantDays) / Double(sample) * 100
        let avgAHI = sample == 0
            ? 0
            : days.reduce(0) { $0 + $1.ahi } / Double(sample)
        let gis = days.compactMap(\.glasgowIndex)
        let avgGI = gis.isEmpty ? nil : gis.reduce(0, +) / Double(gis.count)
        let avgUsageMinutes = sample == 0
            ? 0
            : days.reduce(0) { $0 + $1.usageMinutes } / Double(sample)
        let pressures = days.compactMap(\.pressure95)
        let avgP95 = pressures.isEmpty
            ? nil
            : pressures.reduce(0, +) / Double(pressures.count)
        let leaks = days.compactMap(\.leak95LPerMin)
        let avgLeak = leaks.isEmpty
            ? nil
            : leaks.reduce(0, +) / Double(leaks.count)
        let largePcts = days.compactMap { stat -> Double? in
            guard let seconds = stat.largeLeakSeconds,
                  stat.usageMinutes > 0 else { return nil }
            return seconds / (stat.usageMinutes * 60) * 100
        }
        let avgLargePct = largePcts.isEmpty
            ? nil
            : largePcts.reduce(0, +) / Double(largePcts.count)

        let trends = trendBuckets(days: days)

        return OverviewNarrativeInput(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            sampleSize: sample,
            compliancePercent: PromptRounding.round1(compliance),
            avgAHI: PromptRounding.round1(avgAHI),
            avgGlasgowIndex: avgGI.map(PromptRounding.round2),
            avgUsageMinutes: PromptRounding.toInt(avgUsageMinutes),
            avgPressure95: avgP95.map(PromptRounding.round1),
            avgLeak95LPerMin: avgLeak.map(PromptRounding.toInt),
            avgLargeLeakPercent: avgLargePct.map(PromptRounding.round1),
            trends: trends
        )
    }

    /// Very coarse trend bucketing — split the range in half and
    /// compare the means. For metrics where lower is better (AHI,
    /// leak, GI), "improving" means the second half dropped below
    /// a per-metric noise floor. Usage flips the polarity.
    private static func trendBuckets(
        days: [DailyStatistics]
    ) -> OverviewNarrativeInput.Trends {
        let sorted = days.sorted { $0.date < $1.date }
        guard sorted.count >= 4 else {
            return OverviewNarrativeInput.Trends(
                ahi: .notEnoughData,
                usage: .notEnoughData,
                glasgowIndex: .notEnoughData,
                leak: .notEnoughData
            )
        }
        let mid = sorted.count / 2
        let first = Array(sorted.prefix(mid))
        let second = Array(sorted.suffix(from: mid))

        func direction(
            firstHalf: [Double],
            secondHalf: [Double],
            noiseFloor: Double,
            lowerIsBetter: Bool
        ) -> TrendBucket {
            guard firstHalf.count >= 2, secondHalf.count >= 2 else {
                return .notEnoughData
            }
            let firstMean = firstHalf.reduce(0, +) / Double(firstHalf.count)
            let secondMean = secondHalf.reduce(0, +) / Double(secondHalf.count)
            let delta = secondMean - firstMean
            guard abs(delta) > noiseFloor else { return .stable }
            let improved = lowerIsBetter ? delta < 0 : delta > 0
            return improved ? .improving : .worsening
        }

        let ahiBucket = direction(
            firstHalf: first.map(\.ahi),
            secondHalf: second.map(\.ahi),
            noiseFloor: 0.5,
            lowerIsBetter: true
        )
        let usageBucket = direction(
            firstHalf: first.map(\.usageHours),
            secondHalf: second.map(\.usageHours),
            noiseFloor: 0.4,
            lowerIsBetter: false
        )
        let giBucket = direction(
            firstHalf: first.compactMap(\.glasgowIndex),
            secondHalf: second.compactMap(\.glasgowIndex),
            noiseFloor: 0.1,
            lowerIsBetter: true
        )
        let leakBucket = direction(
            firstHalf: first.compactMap(\.leak95LPerMin),
            secondHalf: second.compactMap(\.leak95LPerMin),
            noiseFloor: 2.0,
            lowerIsBetter: true
        )

        return OverviewNarrativeInput.Trends(
            ahi: ahiBucket,
            usage: usageBucket,
            glasgowIndex: giBucket,
            leak: leakBucket
        )
    }

    // MARK: - Metric explain

    /// Canonical norms per explainable metric. Kept in Swift so the
    /// model never has to guess at clinical cutoffs — it's handed
    /// the boundary values directly.
    public static func norms(for metric: ExplainableMetric) -> MetricExplainInput.Norms {
        switch metric {
        case .ahi:
            return MetricExplainInput.Norms(
                goodMax: 5.0,
                elevatedMax: 15.0,
                description: "AHI under 5 is the usual clinical cutoff for controlled therapy. 5 to 15 is mild; above 15 is typically considered uncontrolled."
            )
        case .glasgowIndex:
            return MetricExplainInput.Norms(
                goodMax: 2.0,
                elevatedMax: 3.0,
                description: "The Glasgow Index is a breath-quality score derived from the flow-rate signal. Each inspiration is rated against nine characteristics associated with flow limitation — each scoring 0 to 1 — so the overall nightly index can in theory range from 0 to 9. This index is informational only and is not a medical diagnostic tool."
            )
        case .pressure95:
            return MetricExplainInput.Norms(
                goodMax: nil,
                elevatedMax: nil,
                description: "EPAP stands for Expiratory Positive Airway Pressure — the cushion of air the CPAP holds against the user's exhalation to keep the upper airway from collapsing. The value shown is the 95th-percentile target: the pressure the device held for all but the top 5% of the night. The optional IPAP subtitle, when present, is the matching 95th-percentile inspiratory pressure; on plain CPAP therapy IPAP equals EPAP so the card hides it. Typical auto-titrating therapy sits between 6 and 14 cmH₂O."
            )
        case .epr:
            return MetricExplainInput.Norms(
                goodMax: nil,
                elevatedMax: nil,
                description: "IPAP stands for Inspiratory Positive Airway Pressure — the pressure the CPAP delivers while the user is breathing in, making inhalation feel easier than it would against EPAP alone. The value shown is the 95th-percentile target. IPAP equals EPAP on plain CPAP therapy and sits above it when EPR (Expiratory Pressure Relief) or bilevel therapy is active; the IPAP−EPAP gap is the extra pressure delivered on inhalation."
            )
        case .leak95:
            return MetricExplainInput.Norms(
                goodMax: 5.0,
                elevatedMax: 24.0,
                description: "Leak under 5 L/min is considered good. ResMed flags leak above 24 L/min as 'large leak' territory."
            )
        case .largeLeak:
            return MetricExplainInput.Norms(
                goodMax: 0.5,
                elevatedMax: 5.0,
                description: "Percent of usage spent above 24 L/min leak. Under 0.5% of usage is healthy; above 5% often indicates a mask fit issue."
            )
        case .tidalVolume:
            return MetricExplainInput.Norms(
                goodMax: 600,
                elevatedMax: 700,
                description: "Median tidal volume. A typical adult sits between 420 and 600 mL; values outside that window warrant attention."
            )
        case .usage:
            return MetricExplainInput.Norms(
                goodMax: 7.0,
                elevatedMax: 9.0,
                description: "Total hours the mask was on and delivering therapy last night. The standard CPAP-compliance threshold used by insurers and sleep clinics is 4 hours. 7 to 9 hours is the typical healthy-adult sleep window. Values below 4 hours are short usage; above 10 hours often reflects wearing the mask while awake or napping."
            )
        case .timeInApnea:
            return MetricExplainInput.Norms(
                goodMax: 1.0,
                elevatedMax: 3.0,
                description: "Percentage of usage time spent inside obstructive, central, or hypopnea events. Snorecard treats under 1% as healthy, 1–3% as elevated, and above 3% as high. This is a tighter read than the AHI bands because it weighs event duration, not just count."
            )
        case .flowLimit:
            return MetricExplainInput.Norms(
                goodMax: 0.05,
                elevatedMax: 0.10,
                description: "95th-percentile flow-limitation score on a 0 to 1 scale, derived from inspiratory flow-waveform shape. 0 means smooth unobstructed breaths; values approaching 1 mean most inspirations showed flattening or shape distortion. Under 0.05 is good, 0.05–0.10 is elevated, above 0.10 commonly indicates upper-airway resistance that therapy hasn't fully resolved."
            )
        case .compliance:
            return MetricExplainInput.Norms(
                goodMax: 100,
                elevatedMax: nil,
                description: "Compliance is the percentage of nights in the selected range with at least 4 hours of usage. 4 hours is the standard threshold insurers and sleep clinics use to count a night as \"on therapy\". 70% and above is typically considered strong adherence; anything lower indicates a pattern of short or skipped nights."
            )
        case .daysWithData:
            return MetricExplainInput.Norms(
                goodMax: nil,
                elevatedMax: nil,
                description: "The number of nights in the selected range that produced any CPAP data. More days of data make averages and trends more reliable; a small number means the window is short and any conclusions are tentative."
            )
        case .sessionsPerNight:
            return MetricExplainInput.Norms(
                goodMax: 1.5,
                elevatedMax: 3.0,
                description: "Each session is one continuous stretch of mask-on time. Averaging close to 1 means you typically sleep straight through; higher averages indicate the mask comes off and goes back on (bathroom trips, waking up, adjusting the fit). Not inherently good or bad; it's contextual information."
            )
        }
    }

    /// Build a `MetricExplainInput` for `metric` using `stats` for
    /// the current value and a trailing range for recent-anchor
    /// context. Returns `nil` when the metric has no value for
    /// this night (e.g. pressure95 is missing on AirSense 11 days
    /// where STR.edf is empty).
    public static func metricExplain(
        metric: ExplainableMetric,
        stats: DailyStatistics,
        trailing: [DailyStatistics]
    ) -> MetricExplainInput? {
        guard let value = rawValue(of: metric, in: stats) else { return nil }
        let trailingValues = trailing.compactMap { rawValue(of: metric, in: $0) }
        let mean: Double? = trailingValues.isEmpty
            ? nil
            : trailingValues.reduce(0, +) / Double(trailingValues.count)
        let p90: Double? = percentile(trailingValues, 90)
        let unit = unitLabel(for: metric)
        return MetricExplainInput(
            metric: metric,
            currentValue: PromptRounding.round2(value),
            unitLabel: unit,
            norms: norms(for: metric),
            recent14DayMean: mean.map(PromptRounding.round2),
            recent14DayP90: p90.map(PromptRounding.round2)
        )
    }

    static func rawValue(of metric: ExplainableMetric, in stats: DailyStatistics) -> Double? {
        switch metric {
        case .ahi:              return stats.ahi
        case .glasgowIndex:     return stats.glasgowIndex
        // `DayDetailView`'s EPAP card sources `epap95` (target
        // EPAP), not `pressure95` (measured mask P95). Feed the
        // explain sheet the same value so the number at the top
        // of the sheet matches the card the user tapped.
        case .pressure95:       return stats.epap95
        case .epr:              return stats.ipap95
        case .leak95:           return stats.leak95LPerMin
        case .largeLeak:
            guard let seconds = stats.largeLeakSeconds,
                  stats.usageMinutes > 0 else { return nil }
            return seconds / (stats.usageMinutes * 60) * 100
        case .tidalVolume:
            return stats.tidalVolume50.map { $0 * 1000 }
        case .usage:            return stats.usageHours
        case .timeInApnea:
            guard let seconds = stats.timeInApneaSeconds,
                  stats.usageMinutes > 0 else { return nil }
            return seconds / (stats.usageMinutes * 60) * 100
        case .flowLimit:        return stats.flowLimit95
        // The Overview-only metrics have no per-day rawValue —
        // they only exist as range aggregates. Return nil so a
        // day-scoped explain is impossible; the caller must use
        // the Overview-scoped builder instead.
        case .compliance:       return nil
        case .daysWithData:     return nil
        case .sessionsPerNight: return nil
        }
    }

    /// Build a `MetricExplainInput` for an Overview-style card,
    /// where `averageValue` is already computed (e.g. mean AHI
    /// across the filtered range). `rangeContext` reframes the
    /// prompt so the narration describes an aggregate, not a
    /// single night. No `recent14DayMean` is supplied because
    /// the aggregate is the anchor.
    public static func overviewMetricExplain(
        metric: ExplainableMetric,
        averageValue: Double,
        rangeStart: Date,
        rangeEnd: Date,
        sampleSize: Int
    ) -> MetricExplainInput {
        MetricExplainInput(
            metric: metric,
            currentValue: PromptRounding.round2(averageValue),
            unitLabel: unitLabel(for: metric),
            norms: norms(for: metric),
            recent14DayMean: nil,
            recent14DayP90: nil,
            rangeContext: MetricExplainInput.RangeContext(
                start: rangeStart,
                end: rangeEnd,
                sampleSize: sampleSize
            )
        )
    }

    static func unitLabel(for metric: ExplainableMetric) -> String {
        switch metric {
        case .ahi:              return "events per hour"
        case .glasgowIndex:     return "score"
        case .pressure95:       return "cmH₂O"
        case .epr:              return "cmH₂O"
        case .leak95:           return "L/min"
        case .largeLeak:        return "percent of usage"
        case .tidalVolume:      return "mL"
        case .usage:            return "hours"
        case .timeInApnea:      return "percent of usage"
        case .flowLimit:        return "score (0–1)"
        case .compliance:       return "percent of nights"
        case .daysWithData:     return "nights"
        case .sessionsPerNight: return "sessions"
        }
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values[0] }
        var sorted = values
        sorted.sort()
        let rank = (p / 100) * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        let frac = rank - Double(low)
        return sorted[low] * (1 - frac) + sorted[high] * frac
    }
}
