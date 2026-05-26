import Foundation
import FoundationModels

/// Metrics that support the tap-to-explain affordance on the daily
/// view. The enum is closed so the prompt and the view layer agree
/// on which explanations exist.
public enum ExplainableMetric: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case ahi
    case glasgowIndex
    case reraIndex
    case epap95
    case ipap95
    case maskPressureMedian
    case leak95
    case largeLeak
    case tidalVolume
    case snore95
    case usage
    case timeInApnea
    case flowLimit
    // Apple Watch sleep-stage metrics, sourced from
    // `NightlySleepSummary` rather than `DailyStatistics`.
    case deepSleepPercent
    case remSleepPercent
    // Trends-only metrics. No daily equivalents exist for
    // these; they describe the shape of a range as a whole.
    case compliance
    case daysWithData
    case sessionsPerNight

    public var id: String { rawValue }

    /// `true` when this metric's value comes from the watch's
    /// `NightlySleepSummary` instead of the CPAP `DailyStatistics`.
    /// Lets the Library and InputBuilders branch the data lookup
    /// without scattering switch statements.
    public var isSleepStage: Bool {
        switch self {
        case .deepSleepPercent, .remSleepPercent: return true
        default: return false
        }
    }
}

/// Inputs for `explainMetric`. `norms` is always supplied by Swift —
/// the model does not know ResMed/CPAP therapy conventions on its
/// own, so bracket boundaries are injected here for the prompt to
/// repeat rather than invent.
public struct MetricExplainInput: Codable, Hashable, Sendable {
    public let metric: ExplainableMetric
    public let currentValue: Double
    public let unitLabel: String
    public let norms: Norms
    public let recent14DayMean: Double?
    public let recent14DayP90: Double?
    /// When non-nil, `currentValue` is an aggregate over this
    /// range rather than a single night's value. The prompt
    /// frames its description accordingly — "your average AHI
    /// over the last 7 days" instead of "your AHI last night".
    public let rangeContext: RangeContext?

    public struct RangeContext: Codable, Hashable, Sendable {
        public let start: Date
        public let end: Date
        public let sampleSize: Int

        public init(start: Date, end: Date, sampleSize: Int) {
            self.start = start
            self.end = end
            self.sampleSize = sampleSize
        }
    }

    public struct Norms: Codable, Hashable, Sendable {
        public let goodMax: Double?
        public let elevatedMax: Double?
        /// Plain-English description of the norm boundaries to
        /// anchor the model — e.g. "AHI under 5 is the usual
        /// clinical cutoff for controlled therapy."
        public let description: String

        public init(goodMax: Double?, elevatedMax: Double?, description: String) {
            self.goodMax = goodMax
            self.elevatedMax = elevatedMax
            self.description = description
        }
    }

    public init(
        metric: ExplainableMetric,
        currentValue: Double,
        unitLabel: String,
        norms: Norms,
        recent14DayMean: Double?,
        recent14DayP90: Double?,
        rangeContext: RangeContext? = nil
    ) {
        self.metric = metric
        self.currentValue = currentValue
        self.unitLabel = unitLabel
        self.norms = norms
        self.recent14DayMean = recent14DayMean
        self.recent14DayP90 = recent14DayP90
        self.rangeContext = rangeContext
    }
}

extension MetricExplainInput {
    /// Plain-English rendering for embedding in the prompt.
    ///
    /// Placement (which band the value falls into) and the
    /// recent-average comparison are pre-digested on the Swift
    /// side and handed to the model as qualitative phrases. The
    /// on-device 3B model confabulated numeric boundaries when it
    /// was shown raw "Boundary for 'good': up to X" lines next to
    /// the reader's value — it extended the word "boundary" to
    /// the 14-day mean and invented cutoffs that weren't in the
    /// input. Swift owning the arithmetic avoids that whole class
    /// of hallucination.
    public var promptDescription: String {
        var lines: [String] = []
        lines.append("Metric: \(metric.displayLabel)")
        if let range = rangeContext {
            lines.append("Scope: average over \(Self.rangeFormatter.string(from: range.start)) to \(Self.rangeFormatter.string(from: range.end)) (\(range.sampleSize) nights with data)")
            lines.append("Your average value: \(Self.formatValue(currentValue, metric: metric)) \(unitLabel)")
        } else {
            lines.append("Scope: a single night")
            lines.append("Your current value: \(Self.formatValue(currentValue, metric: metric)) \(unitLabel)")
        }
        if let placement = Self.placementPhrase(
            for: metric,
            currentValue: currentValue
        ) {
            lines.append("Placement: \(placement)")
        }
        if let mean = recent14DayMean,
           let relation = Self.meanRelationPhrase(
                for: metric,
                currentValue: currentValue,
                mean: mean
           ) {
            lines.append("Compared with your recent average: \(relation)")
        }
        var body = lines.map { "- \($0)" }.joined(separator: "\n")
        body += "\n\nContext for the metric:\n\(norms.description)"
        return body
    }

    /// Qualitative band the reader's value falls into, for each
    /// metric that has clinical bands. Returns nil when the
    /// metric has no meaningful banding (EPAP/IPAP targets,
    /// median mask pressure, days with data, sessions per night).
    static func placementPhrase(
        for metric: ExplainableMetric,
        currentValue v: Double
    ) -> String? {
        switch metric {
        case .ahi:
            if v <= 5 { return "in the controlled range" }
            if v <= 15 { return "in the mild range" }
            return "above the mild range"
        case .glasgowIndex:
            if v <= 2.0 { return "in the good band" }
            if v <= 3.0 { return "in the elevated band" }
            return "above the elevated band"
        case .reraIndex:
            if v <= 5 { return "in the controlled range" }
            if v <= 15 { return "in the mild range" }
            return "above the mild range"
        case .leak95:
            if v <= 5 { return "well sealed" }
            if v <= 24 { return "below the large-leak threshold" }
            return "above the large-leak threshold"
        case .largeLeak:
            if v <= 0.5 { return "negligible" }
            if v <= 5 { return "elevated" }
            return "high"
        case .timeInApnea:
            if v <= 1 { return "in the healthy range" }
            if v <= 3 { return "elevated" }
            return "high"
        case .flowLimit:
            if v <= 0.05 { return "in the good band" }
            if v <= 0.10 { return "in the elevated band" }
            return "above the elevated band"
        case .snore95:
            if v <= 1 { return "quiet" }
            if v <= 3 { return "mild or intermittent" }
            return "loud or sustained"
        case .usage:
            if v < 4 { return "below the compliance threshold" }
            if v < 7 { return "short of the typical 7 to 9 hour window" }
            if v <= 9 { return "inside the typical 7 to 9 hour window" }
            if v <= 10 { return "above the typical window" }
            return "unusually long"
        case .tidalVolume:
            if v < 350 { return "well below the typical adult range" }
            if v < 420 { return "just below the typical adult range" }
            if v <= 600 { return "inside the typical adult range" }
            if v <= 700 { return "just above the typical adult range" }
            return "well above the typical adult range"
        case .deepSleepPercent:
            // Adult deep-sleep references vary; 13–23 % of total
            // sleep is the most commonly cited typical band, with
            // declines pronounced after middle age.
            if v < 10 { return "below the typical adult range" }
            if v <= 23 { return "inside the typical adult range" }
            return "above the typical adult range"
        case .remSleepPercent:
            // Adult REM is typically 20–25 % of total sleep, with
            // 18–30 % the broader "within normal limits" envelope.
            if v < 18 { return "below the typical adult range" }
            if v <= 30 { return "inside the typical adult range" }
            return "above the typical adult range"
        case .compliance:
            if v >= 70 { return "strong adherence" }
            if v >= 50 { return "mixed adherence" }
            return "inconsistent adherence"
        case .epap95, .ipap95, .maskPressureMedian,
             .daysWithData, .sessionsPerNight:
            return nil
        }
    }

    /// Qualitative relation between the reader's value and their
    /// trailing 14-day mean. Each metric gets a noise floor so
    /// float drift doesn't flip "in line" into "noticeably
    /// above". Returns nil for metrics where the 14-day mean is
    /// never supplied in practice (compliance, trends-only).
    static func meanRelationPhrase(
        for metric: ExplainableMetric,
        currentValue v: Double,
        mean: Double
    ) -> String? {
        let noiseFloor: Double
        switch metric {
        case .ahi:              noiseFloor = 0.5
        case .glasgowIndex:     noiseFloor = 0.15
        case .reraIndex:        noiseFloor = 0.5
        case .usage:            noiseFloor = 0.4
        case .leak95:           noiseFloor = 3
        case .largeLeak:        noiseFloor = 0.5
        case .timeInApnea:      noiseFloor = 0.5
        case .flowLimit:        noiseFloor = 0.02
        case .snore95:          noiseFloor = 0.3
        case .tidalVolume:      noiseFloor = 25
        case .deepSleepPercent: noiseFloor = 2
        case .remSleepPercent:  noiseFloor = 2
        case .epap95, .ipap95, .maskPressureMedian:
            noiseFloor = 0.3
        case .compliance, .daysWithData, .sessionsPerNight:
            return nil
        }
        let delta = v - mean
        if abs(delta) <= noiseFloor {
            return "in line with your recent average"
        }
        return delta > 0
            ? "noticeably above your recent average"
            : "noticeably below your recent average"
    }

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static func formatValue(_ value: Double, metric: ExplainableMetric) -> String {
        switch metric {
        case .largeLeak:        return String(format: "%.1f", value)
        case .leak95:           return String(format: "%.0f", value)
        case .tidalVolume:      return String(format: "%.0f", value)
        case .glasgowIndex:     return String(format: "%.2f", value)
        case .daysWithData:     return String(format: "%.0f", value)
        case .sessionsPerNight: return String(format: "%.1f", value)
        case .compliance:       return String(format: "%.0f", value)
        case .deepSleepPercent,
             .remSleepPercent:  return String(format: "%.0f", value)
        default:                return String(format: "%.1f", value)
        }
    }
}

extension ExplainableMetric {
    /// Human-friendly label for the metric. Matches the card
    /// titles used in `DayDetailView` so the model never sees
    /// an enum raw value like "pressure95" in the prompt.
    public var displayLabel: String {
        switch self {
        case .ahi:              return "AHI"
        case .glasgowIndex:     return "Glasgow Index"
        case .reraIndex:        return "NED Analysis (RERA events per hour)"
        case .epap95:           return "EPAP (95th percentile target)"
        case .ipap95:           return "IPAP (95th percentile target)"
        case .maskPressureMedian: return "Mask pressure (median during usage)"
        case .leak95:           return "Leak (95th percentile)"
        case .largeLeak:        return "Large leak (percent of usage)"
        case .tidalVolume:      return "Tidal volume (median)"
        case .snore95:          return "Snore (95th percentile, 0–5 scale)"
        case .usage:            return "Usage hours"
        case .timeInApnea:      return "Time in apnea (percent of usage)"
        case .flowLimit:        return "Flow limit (95th percentile)"
        case .compliance:       return "Compliance (percent of nights meeting the user's per-night usage target)"
        case .daysWithData:     return "Days with recorded data"
        case .sessionsPerNight: return "Sessions per night"
        case .deepSleepPercent: return "Deep sleep (percent of asleep time, from Apple Watch)"
        case .remSleepPercent:  return "REM sleep (percent of asleep time, from Apple Watch)"
        }
    }
}

@Generable
public struct MetricExplainOutput: Codable, Hashable, Sendable {
    @Guide(description: "1 or 2 sentences defining what the metric represents. Plain English. The first sentence must begin with the metric's name or a natural paraphrase of it (e.g. \"The AHI…\", \"Your compliance score…\") — never with \"This metric\", \"This value\", or a bare pronoun. Do not repeat the user's numeric value here.")
    public let whatItMeans: String

    @Guide(description: "1 or 2 sentences putting the user's current value in context compared to the provided norms and recent mean. No advice, no recommendations, no causal verbs.")
    public let howYoursLooks: String

    public init(whatItMeans: String, howYoursLooks: String) {
        self.whatItMeans = whatItMeans
        self.howYoursLooks = howYoursLooks
    }
}
