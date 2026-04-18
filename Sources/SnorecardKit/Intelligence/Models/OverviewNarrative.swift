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

/// Aggregate stats for the current Overview range, canonicalised
/// before hashing. `sampleSize` is the count of days-with-data so
/// the model can calibrate confidence.
public struct OverviewNarrativeInput: Codable, Hashable, Sendable {
    public let rangeStart: Date
    public let rangeEnd: Date
    public let sampleSize: Int
    public let compliancePercent: Double    // 1 dp
    public let avgAHI: Double               // 1 dp
    public let avgGlasgowIndex: Double?     // 2 dp
    public let avgUsageMinutes: Int
    public let avgPressure95: Double?       // 1 dp
    public let avgLeak95LPerMin: Int?
    public let avgLargeLeakPercent: Double? // 1 dp
    public let trends: Trends

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
        avgAHI: Double,
        avgGlasgowIndex: Double?,
        avgUsageMinutes: Int,
        avgPressure95: Double?,
        avgLeak95LPerMin: Int?,
        avgLargeLeakPercent: Double?,
        trends: Trends
    ) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.sampleSize = sampleSize
        self.compliancePercent = compliancePercent
        self.avgAHI = avgAHI
        self.avgGlasgowIndex = avgGlasgowIndex
        self.avgUsageMinutes = avgUsageMinutes
        self.avgPressure95 = avgPressure95
        self.avgLeak95LPerMin = avgLeak95LPerMin
        self.avgLargeLeakPercent = avgLargeLeakPercent
        self.trends = trends
    }
}

@Generable
public struct OverviewNarrativeOutput: Codable, Hashable, Sendable {
    @Guide(description: "3 to 5 sentences describing direction of travel over the range. British English. No advice, no causal claims, no recommendations.")
    public let paragraph: String

    @Guide(description: "Optional single-line takeaway, fewer than 12 words. Describe, don't prescribe.")
    public let highlight: String?

    public init(paragraph: String, highlight: String?) {
        self.paragraph = paragraph
        self.highlight = highlight
    }
}
