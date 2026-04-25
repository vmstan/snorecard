import Foundation
import FoundationModels

/// Direction-of-travel bucket for a metric over a range. We only
/// ever hand the model these buckets, never raw per-day values, so
/// the model can't invent trend lines it hasn't seen.
public enum TrendBucket: String, Codable, Hashable, Sendable {
    case improving
    case stable
    case worsening
    case notEnoughData
}

/// Aggregate stats for the current Trends range, canonicalised
/// before hashing. `sampleSize` is the count of days-with-data so
/// the model can calibrate confidence.
public struct TrendsNarrativeInput: Codable, Hashable, Sendable {
    public let rangeStart: Date
    public let rangeEnd: Date
    public let sampleSize: Int
    public let compliancePercent: Double    // 1 dp
    public let complianceTargetHours: Double // user's per-night target
    public let avgAHI: Double               // 1 dp
    public let avgGlasgowIndex: Double?     // 2 dp
    public let avgUsageMinutes: Int
    public let avgPressure95: Double?       // 1 dp
    public let avgLeak95LPerMin: Int?
    public let avgLargeLeakPercent: Double? // 1 dp
    public let trends: Trends
    /// Apple Watch sleep-stage averages over the same range. `nil`
    /// when no nights in the range had a watch summary.
    public let sleepStages: SleepStages?

    public struct SleepStages: Codable, Hashable, Sendable {
        public let nightsWithStages: Int
        public let avgTotalAsleepHours: Double  // 1 dp
        public let avgDeepPercent: Double       // 1 dp
        public let avgCorePercent: Double       // 1 dp
        public let avgRemPercent: Double        // 1 dp

        public init(
            nightsWithStages: Int,
            avgTotalAsleepHours: Double,
            avgDeepPercent: Double,
            avgCorePercent: Double,
            avgRemPercent: Double
        ) {
            self.nightsWithStages = nightsWithStages
            self.avgTotalAsleepHours = avgTotalAsleepHours
            self.avgDeepPercent = avgDeepPercent
            self.avgCorePercent = avgCorePercent
            self.avgRemPercent = avgRemPercent
        }
    }

    public struct Trends: Codable, Hashable, Sendable {
        public let ahi: TrendBucket
        public let usage: TrendBucket
        public let glasgowIndex: TrendBucket
        public let leak: TrendBucket

        public init(
            ahi: TrendBucket,
            usage: TrendBucket,
            glasgowIndex: TrendBucket,
            leak: TrendBucket
        ) {
            self.ahi = ahi
            self.usage = usage
            self.glasgowIndex = glasgowIndex
            self.leak = leak
        }
    }

    public init(
        rangeStart: Date,
        rangeEnd: Date,
        sampleSize: Int,
        compliancePercent: Double,
        complianceTargetHours: Double,
        avgAHI: Double,
        avgGlasgowIndex: Double?,
        avgUsageMinutes: Int,
        avgPressure95: Double?,
        avgLeak95LPerMin: Int?,
        avgLargeLeakPercent: Double?,
        trends: Trends,
        sleepStages: SleepStages? = nil
    ) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.sampleSize = sampleSize
        self.compliancePercent = compliancePercent
        self.complianceTargetHours = complianceTargetHours
        self.avgAHI = avgAHI
        self.avgGlasgowIndex = avgGlasgowIndex
        self.avgUsageMinutes = avgUsageMinutes
        self.avgPressure95 = avgPressure95
        self.avgLeak95LPerMin = avgLeak95LPerMin
        self.avgLargeLeakPercent = avgLargeLeakPercent
        self.trends = trends
        self.sleepStages = sleepStages
    }
}

extension TrendsNarrativeInput {
    /// Plain-English rendering of the range for embedding in a
    /// prompt. Avoids JSON keys so the model can't echo internal
    /// identifiers like `avgLeak95LPerMin` into the narration.
    public var promptDescription: String {
        var lines: [String] = []
        lines.append("Range: \(Self.rangeFormatter.string(from: rangeStart)) to \(Self.rangeFormatter.string(from: rangeEnd))")
        lines.append("Days with data: \(sampleSize)")
        lines.append("Compliance: \(Self.oneDp(compliancePercent))% of nights with usage ≥ \(Self.formatHours(complianceTargetHours))")
        lines.append("Average AHI: \(Self.oneDp(avgAHI)) events per hour")
        if let gi = avgGlasgowIndex {
            lines.append("Average Glasgow Index: \(Self.twoDp(gi))")
        }
        let usageHours = Double(avgUsageMinutes) / 60
        lines.append("Average usage: \(Self.oneDp(usageHours)) hours per night")
        if let p = avgPressure95 {
            lines.append("Average pressure (95th percentile): \(Self.oneDp(p)) cmH2O")
        }
        if let leak = avgLeak95LPerMin {
            lines.append("Average leak (95th percentile): \(leak) L/min")
        }
        if let large = avgLargeLeakPercent {
            lines.append("Average time above large-leak threshold: \(Self.oneDp(large))% of usage")
        }
        if let stages = sleepStages {
            lines.append("Apple Watch nights with stage data: \(stages.nightsWithStages)")
            lines.append("Apple Watch average total sleep: \(Self.oneDp(stages.avgTotalAsleepHours)) hours per night")
            lines.append("Apple Watch average deep sleep: \(Self.oneDp(stages.avgDeepPercent))% of asleep time")
            lines.append("Apple Watch average core sleep: \(Self.oneDp(stages.avgCorePercent))% of asleep time")
            lines.append("Apple Watch average REM sleep: \(Self.oneDp(stages.avgRemPercent))% of asleep time")
        }

        var body = lines.map { "- \($0)" }.joined(separator: "\n")

        let buckets = [
            ("AHI", trends.ahi),
            ("Usage", trends.usage),
            ("Glasgow Index", trends.glasgowIndex),
            ("Leak", trends.leak)
        ]
        body += "\n\nTrend direction over the range (computed, not for you to invent):\n"
        body += buckets
            .map { "- \($0.0): \(Self.trendLabel($0.1))" }
            .joined(separator: "\n")

        return body
    }

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static func oneDp(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func twoDp(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func formatHours(_ hours: Double) -> String {
        if hours.rounded() == hours {
            return "\(Int(hours)) hours"
        }
        return String(format: "%.1f hours", hours)
    }

    private static func trendLabel(_ bucket: TrendBucket) -> String {
        switch bucket {
        case .improving:      return "improving"
        case .stable:         return "stable"
        case .worsening:      return "worsening"
        case .notEnoughData:  return "not enough data"
        }
    }
}

@Generable
public struct TrendsNarrativeOutput: Codable, Hashable, Sendable {
    @Guide(description: "3 to 5 sentences describing direction of travel over the range. British English. No advice, no causal claims, no recommendations.")
    public let paragraph: String

    @Guide(description: "Optional single-line takeaway, fewer than 12 words. Describe, don't prescribe.")
    public let highlight: String?

    public init(paragraph: String, highlight: String?) {
        self.paragraph = paragraph
        self.highlight = highlight
    }
}
