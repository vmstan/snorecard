import Foundation

/// Pure helpers that shape raw `DailyStatistics` into the canonical,
/// rounded inputs each Intelligence prompt expects. Kept separate
/// from the prompt builders so test fixtures can drive the prompt
/// builders directly without reaching for real statistics.
public enum IntelligenceInputBuilder {

    // MARK: - Night summary

    /// Build a `NightSummaryInput` from the single night's stats, an
    /// optional trailing baseline, an optional user note, and an
    /// optional Apple Watch sleep summary. Values are rounded to
    /// the precision declared on `NightSummaryInput` so float drift
    /// doesn't invalidate cached entries.
    public static func nightSummary(
        stats: DailyStatistics,
        baseline: Baseline?,
        userNote: String?,
        subjectiveScore: Int? = nil,
        userTags: [NoteTag] = [],
        sleepSummary: NightlySleepSummary? = nil,
        excludeCentralFromAHI: Bool = false
    ) -> NightSummaryInput {
        let usageHours = PromptRounding.round1(stats.usageHours)
        // The user can hide CA events from the UI via an Appearance
        // preference. When that's on, the prompt sees the same AHI
        // the user reads on screen — otherwise the narrative would
        // anchor on a number the user can't find anywhere in the app.
        let ahi = PromptRounding.round1(
            stats.displayedAHI(includingCentral: !excludeCentralFromAHI)
        )
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
            // Project through the same CA-display preference the
            // headline AHI uses so the narrative's percentage and
            // the daily card stay in lockstep when CA is hidden.
            guard let seconds = stats.displayedTimeInApneaSeconds(
                    includingCentral: !excludeCentralFromAHI
                  ),
                  stats.usageMinutes > 0 else { return nil }
            return PromptRounding.round1(seconds / (stats.usageMinutes * 60) * 100)
        }()
        let tidalMedianML = stats.tidalVolume50.map { PromptRounding.toInt($0 * 1000) }

        let diff = baseline.map { baseline -> NightSummaryInput.BaselineDiff in
            // `baseline.ahi` is computed by `trailing14`, which here
            // is also given the CA-excluded preference, so both sides
            // of the delta use the same projection.
            let nightlyAHI = stats.displayedAHI(includingCentral: !excludeCentralFromAHI)
            return NightSummaryInput.BaselineDiff(
                ahiDelta: PromptRounding.round1(nightlyAHI - baseline.ahi),
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

        // Clamp the subjective score into the 1–5 range the UI
        // produces — defensive in case a future caller passes
        // unclamped input, but a no-op today.
        let clampedScore: Int? = subjectiveScore.map { min(max($0, 1), 5) }
        let tagLabels = userTags.map(\.displayLabel)

        // Sleep-stage summary, only when the watch actually has a
        // night to report on (otherwise the model sees no stage
        // line and won't be able to invent one).
        let stagesInput: NightSummaryInput.SleepStages? = {
            guard let summary = sleepSummary,
                  summary.timeAsleep > 0 else { return nil }
            return NightSummaryInput.SleepStages(
                totalAsleepHours: PromptRounding.round1(summary.timeAsleep / 3600),
                deepPercent: PromptRounding.round1(summary.fractionAsleep(in: .deep) * 100),
                corePercent: PromptRounding.round1(summary.fractionAsleep(in: .core) * 100),
                remPercent: PromptRounding.round1(summary.fractionAsleep(in: .rem) * 100)
            )
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
            userNote: trimmedNote,
            subjectiveScore: clampedScore,
            userTags: tagLabels,
            sleepStages: stagesInput
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
            from stats: [DailyStatistics],
            excludeCentralFromAHI: Bool = false
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
            let ahi = window.reduce(0) {
                $0 + $1.displayedAHI(includingCentral: !excludeCentralFromAHI)
            } / Double(window.count)
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

    // MARK: - Trends narrative

    /// Shape a `TrendsNarrativeInput` from the filtered stats in
    /// a range. `sampleSize` is the count of days with usage; the
    /// model calibrates confidence against that. `complianceTargetHours`
    /// is the user-chosen hours/night threshold — defaults to the
    /// insurer standard of 4 so callers that don't know the device's
    /// preference still get sensible numbers.
    public static func trendsNarrative(
        stats: [DailyStatistics],
        rangeStart: Date,
        rangeEnd: Date,
        complianceTargetHours: Double = 4,
        sleepSummaries: [NightlySleepSummary] = [],
        excludeCentralFromAHI: Bool = false
    ) -> TrendsNarrativeInput {
        let days = stats.filter(\.hasUsage)
        let sample = days.count
        let compliantDays = days.filter { $0.usageHours >= complianceTargetHours }.count
        let compliance = sample == 0
            ? 0
            : Double(compliantDays) / Double(sample) * 100
        let avgAHI = sample == 0
            ? 0
            : days.reduce(0) {
                $0 + $1.displayedAHI(includingCentral: !excludeCentralFromAHI)
            } / Double(sample)
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

        let trends = trendBuckets(days: days, excludeCentralFromAHI: excludeCentralFromAHI)

        // Apple Watch sleep-stage averages — only computed from
        // nights with non-zero asleep time (otherwise the
        // fractions are undefined).
        let scoredStages = sleepSummaries.filter { $0.timeAsleep > 0 }
        let stagesInput: TrendsNarrativeInput.SleepStages? = {
            guard !scoredStages.isEmpty else { return nil }
            let count = Double(scoredStages.count)
            let totalAsleepHours = scoredStages.reduce(0) { $0 + $1.timeAsleep / 3600 } / count
            let deepPct = scoredStages.reduce(0) { $0 + $1.fractionAsleep(in: .deep) } / count * 100
            let corePct = scoredStages.reduce(0) { $0 + $1.fractionAsleep(in: .core) } / count * 100
            let remPct = scoredStages.reduce(0) { $0 + $1.fractionAsleep(in: .rem) } / count * 100
            return TrendsNarrativeInput.SleepStages(
                nightsWithStages: scoredStages.count,
                avgTotalAsleepHours: PromptRounding.round1(totalAsleepHours),
                avgDeepPercent: PromptRounding.round1(deepPct),
                avgCorePercent: PromptRounding.round1(corePct),
                avgRemPercent: PromptRounding.round1(remPct)
            )
        }()

        return TrendsNarrativeInput(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            sampleSize: sample,
            compliancePercent: PromptRounding.round1(compliance),
            complianceTargetHours: PromptRounding.round1(complianceTargetHours),
            avgAHI: PromptRounding.round1(avgAHI),
            avgGlasgowIndex: avgGI.map(PromptRounding.round2),
            avgUsageMinutes: PromptRounding.toInt(avgUsageMinutes),
            avgPressure95: avgP95.map(PromptRounding.round1),
            avgLeak95LPerMin: avgLeak.map(PromptRounding.toInt),
            avgLargeLeakPercent: avgLargePct.map(PromptRounding.round1),
            trends: trends,
            sleepStages: stagesInput
        )
    }

    /// Very coarse trend bucketing — split the range in half and
    /// compare the means. For metrics where lower is better (AHI,
    /// leak, GI), "improving" means the second half dropped below
    /// a per-metric noise floor. Usage flips the polarity.
    private static func trendBuckets(
        days: [DailyStatistics],
        excludeCentralFromAHI: Bool = false
    ) -> TrendsNarrativeInput.Trends {
        let sorted = days.sorted { $0.date < $1.date }
        guard sorted.count >= 4 else {
            return TrendsNarrativeInput.Trends(
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
            firstHalf: first.map { $0.displayedAHI(includingCentral: !excludeCentralFromAHI) },
            secondHalf: second.map { $0.displayedAHI(includingCentral: !excludeCentralFromAHI) },
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

        return TrendsNarrativeInput.Trends(
            ahi: ahiBucket,
            usage: usageBucket,
            glasgowIndex: giBucket,
            leak: leakBucket
        )
    }

    // MARK: - Metric explain

    /// Canonical norms per explainable metric. Kept in Swift so the
    /// model never has to guess at clinical cutoffs — it's handed
    /// the boundary values directly. `complianceTargetHours` lets
    /// the compliance norm description reflect the user's actual
    /// per-machine target instead of hardcoding the 4-hour insurer
    /// default into the prompt.
    public static func norms(
        for metric: ExplainableMetric,
        complianceTargetHours: Double = 4
    ) -> MetricExplainInput.Norms {
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
        case .epap95:
            return MetricExplainInput.Norms(
                goodMax: nil,
                elevatedMax: nil,
                description: "EPAP — Expiratory Positive Airway Pressure — is the cushion of air the device holds against your exhalation to keep your upper airway from collapsing. The value shown is the 95th-percentile target: the pressure reached or exceeded for all but the top 5% of on-therapy time. Auto-titrating CPAP typically ranges from 6 to 14 cmH2O."
            )
        case .ipap95:
            return MetricExplainInput.Norms(
                goodMax: nil,
                elevatedMax: nil,
                description: "IPAP — Inspiratory Positive Airway Pressure — is the pressure delivered while you're breathing in, making each inhale feel easier than it would against EPAP alone. The value shown is the 95th-percentile target. The gap between IPAP and EPAP is the Pressure Support added on inhalation."
            )
        case .maskPressureMedian:
            return MetricExplainInput.Norms(
                goodMax: nil,
                elevatedMax: nil,
                description: "The median mask pressure measured during on-therapy usage — a typical / middle-of-the-distribution read of what the mask actually held, as distinct from the 95th-percentile target the algorithm is aiming for. Useful for sanity-checking that the device is settling at a comfortable working pressure between its EPAP floor and occasional IPAP peaks."
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
        case .snore95:
            return MetricExplainInput.Norms(
                goodMax: 1.0,
                elevatedMax: 3.0,
                description: "The 95th-percentile snore index on ResMed's 0–5 scale, derived from vibration in the flow signal while on therapy. 0 means quiet breathing; values climb as snoring becomes louder or more persistent. Under 1 is quiet, 1–3 is mild / intermittent, 3 and above is loud or sustained — often a cue to look at mask fit, body position, or residual upper-airway obstruction."
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
            let targetLabel = Self.formatComplianceTarget(complianceTargetHours)
            let insurerClause = complianceTargetHours == 4
                ? " \(targetLabel) is the standard threshold insurers and sleep clinics use to count a night as \"on therapy\"."
                : " The user has set the per-night target to \(targetLabel); insurers and sleep clinics typically use 4 hours as the baseline."
            return MetricExplainInput.Norms(
                goodMax: 100,
                elevatedMax: nil,
                description: "Compliance is the percentage of nights in the selected range with at least \(targetLabel) of usage.\(insurerClause) 70% and above is typically considered strong adherence; anything lower indicates a pattern of short or skipped nights."
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
        case .deepSleepPercent:
            return MetricExplainInput.Norms(
                goodMax: nil,
                elevatedMax: nil,
                description: "Percent of total asleep time spent in deep (slow-wave) sleep, as detected by Apple Watch. Adult deep sleep typically lands between 13% and 23% of total sleep, with a usual decline through middle age. Below 10% is short of the typical band; above ~25% is unusual but not inherently a problem if total sleep duration is normal."
            )
        case .remSleepPercent:
            return MetricExplainInput.Norms(
                goodMax: nil,
                elevatedMax: nil,
                description: "Percent of total asleep time spent in REM sleep, as detected by Apple Watch. Adult REM typically falls between 20% and 25% of total sleep, with 18–30% the broader within-normal-limits envelope. Values outside that band can reflect short sleep, sleep fragmentation, alcohol or medication effects, or measurement noise from the watch itself."
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
        trailing: [DailyStatistics],
        excludeCentralFromAHI: Bool = false
    ) -> MetricExplainInput? {
        guard let value = rawValue(
            of: metric,
            in: stats,
            excludeCentralFromAHI: excludeCentralFromAHI
        ) else { return nil }
        let trailingValues = trailing.compactMap {
            rawValue(of: metric, in: $0, excludeCentralFromAHI: excludeCentralFromAHI)
        }
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

    static func rawValue(
        of metric: ExplainableMetric,
        in stats: DailyStatistics,
        excludeCentralFromAHI: Bool = false
    ) -> Double? {
        switch metric {
        case .ahi:
            return stats.displayedAHI(includingCentral: !excludeCentralFromAHI)
        case .glasgowIndex:     return stats.glasgowIndex
        // `DayDetailView`'s EPAP card sources `epap95` (target
        // EPAP), not `pressure95` (measured mask P95). Feed the
        // explain sheet the same value so the number at the top
        // of the sheet matches the card the user tapped.
        case .epap95:           return stats.epap95
        case .ipap95:           return stats.ipap95
        case .maskPressureMedian: return stats.pressureMedian
        case .leak95:           return stats.leak95LPerMin
        case .largeLeak:
            guard let seconds = stats.largeLeakSeconds,
                  stats.usageMinutes > 0 else { return nil }
            return seconds / (stats.usageMinutes * 60) * 100
        case .tidalVolume:
            return stats.tidalVolume50.map { $0 * 1000 }
        case .snore95:          return stats.snore95
        case .usage:            return stats.usageHours
        case .timeInApnea:
            guard let seconds = stats.displayedTimeInApneaSeconds(
                    includingCentral: !excludeCentralFromAHI
                  ),
                  stats.usageMinutes > 0 else { return nil }
            return seconds / (stats.usageMinutes * 60) * 100
        case .flowLimit:        return stats.flowLimit95
        // The Trends-only metrics have no per-day rawValue —
        // they only exist as range aggregates. Return nil so a
        // day-scoped explain is impossible; the caller must use
        // the Trends-scoped builder instead.
        case .compliance:       return nil
        case .daysWithData:     return nil
        case .sessionsPerNight: return nil
        // Sleep-stage metrics live on `NightlySleepSummary`, not
        // `DailyStatistics`. Return nil here; callers detect the
        // metric kind via `ExplainableMetric.isSleepStage` and use
        // the summary-aware overload below.
        case .deepSleepPercent: return nil
        case .remSleepPercent:  return nil
        }
    }

    /// Sleep-summary-keyed companion to `rawValue(of:in:)`. Only
    /// returns a value for sleep-stage metrics; the CPAP family
    /// always returns nil here so a caller that hands in a summary
    /// for a non-sleep metric falls through to the no-value path
    /// instead of silently producing a wrong number.
    static func rawValue(of metric: ExplainableMetric, in summary: NightlySleepSummary) -> Double? {
        guard summary.timeAsleep > 0 else { return nil }
        switch metric {
        case .deepSleepPercent: return summary.fractionAsleep(in: .deep) * 100
        case .remSleepPercent:  return summary.fractionAsleep(in: .rem) * 100
        default:                return nil
        }
    }

    /// Sleep-stage variant of `metricExplain` — sources the value
    /// from the Apple Watch summary instead of `DailyStatistics`,
    /// and uses the trailing list of summaries for the recent-mean
    /// anchor. Returns nil for non-sleep metrics; the CPAP family
    /// has its own builder above.
    public static func metricExplain(
        metric: ExplainableMetric,
        summary: NightlySleepSummary,
        trailingSummaries: [NightlySleepSummary]
    ) -> MetricExplainInput? {
        guard metric.isSleepStage else { return nil }
        guard let value = rawValue(of: metric, in: summary) else { return nil }
        let trailingValues = trailingSummaries.compactMap { rawValue(of: metric, in: $0) }
        let mean: Double? = trailingValues.isEmpty
            ? nil
            : trailingValues.reduce(0, +) / Double(trailingValues.count)
        let p90: Double? = percentile(trailingValues, 90)
        return MetricExplainInput(
            metric: metric,
            currentValue: PromptRounding.round2(value),
            unitLabel: unitLabel(for: metric),
            norms: norms(for: metric),
            recent14DayMean: mean.map(PromptRounding.round2),
            recent14DayP90: p90.map(PromptRounding.round2)
        )
    }

    /// Build a `MetricExplainInput` for a Trends-style card,
    /// where `averageValue` is already computed (e.g. mean AHI
    /// across the filtered range). `rangeContext` reframes the
    /// prompt so the narration describes an aggregate, not a
    /// single night. No `recent14DayMean` is supplied because
    /// the aggregate is the anchor. `complianceTargetHours`
    /// flows into the compliance norm description so the prompt
    /// reflects the machine's per-night target rather than the
    /// hardcoded 4-hour insurer default.
    public static func trendsMetricExplain(
        metric: ExplainableMetric,
        averageValue: Double,
        rangeStart: Date,
        rangeEnd: Date,
        sampleSize: Int,
        complianceTargetHours: Double = 4
    ) -> MetricExplainInput {
        MetricExplainInput(
            metric: metric,
            currentValue: PromptRounding.round2(averageValue),
            unitLabel: unitLabel(for: metric),
            norms: norms(
                for: metric,
                complianceTargetHours: complianceTargetHours
            ),
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
        case .epap95:           return "cmH2O"
        case .ipap95:           return "cmH2O"
        case .maskPressureMedian: return "cmH2O"
        case .leak95:           return "L/min"
        case .largeLeak:        return "percent of usage"
        case .tidalVolume:      return "mL"
        case .snore95:          return "index (0–5)"
        case .usage:            return "hours"
        case .timeInApnea:      return "percent of usage"
        case .flowLimit:        return "score (0–1)"
        case .compliance:       return "percent of nights"
        case .daysWithData:     return "nights"
        case .sessionsPerNight: return "sessions"
        case .deepSleepPercent,
             .remSleepPercent:  return "percent of asleep time"
        }
    }

    /// Render the compliance target as a short plain-English
    /// label — "4 hours", "5.5 hours" — for the norm description
    /// injected into the explain prompt.
    private static func formatComplianceTarget(_ hours: Double) -> String {
        if hours.rounded() == hours {
            return "\(Int(hours)) hours"
        }
        return String(format: "%.1f hours", hours)
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
