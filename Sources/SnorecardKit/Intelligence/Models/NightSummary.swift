import Foundation
import FoundationModels

/// Structured input for the per-night summary prompt. All numeric
/// fields are canonicalised (rounded to the precision listed in the
/// plan) before being hashed for the cache key, so tiny float drift
/// between iCloud syncs doesn't invalidate an otherwise identical
/// entry.
public struct NightSummaryInput: Codable, Hashable, Sendable {
    public let date: Date
    public let usageHours: Double          // 1 dp
    public let ahi: Double                 // 1 dp
    public let glasgowIndex: Double?       // 2 dp
    public let pressure95: Double?         // 1 dp
    public let eprSupport: Double?         // 1 dp  (ipap95 − epap95)
    public let leak95LPerMin: Int?         // integer
    public let largeLeakPercent: Double?   // 1 dp
    public let timeInApneaPercent: Double? // 1 dp
    public let tidalVolumeMedianML: Int?   // integer
    public let baselineDiff: BaselineDiff?
    public let userNote: String?

    public struct BaselineDiff: Codable, Hashable, Sendable {
        public let ahiDelta: Double        // 1 dp, signed
        public let usageHoursDelta: Double // 1 dp, signed
        public let leakDelta: Double?      // 1 dp, signed
        public let giDelta: Double?        // 2 dp, signed

        public init(
            ahiDelta: Double,
            usageHoursDelta: Double,
            leakDelta: Double?,
            giDelta: Double?
        ) {
            self.ahiDelta = ahiDelta
            self.usageHoursDelta = usageHoursDelta
            self.leakDelta = leakDelta
            self.giDelta = giDelta
        }
    }

    public init(
        date: Date,
        usageHours: Double,
        ahi: Double,
        glasgowIndex: Double?,
        pressure95: Double?,
        eprSupport: Double?,
        leak95LPerMin: Int?,
        largeLeakPercent: Double?,
        timeInApneaPercent: Double?,
        tidalVolumeMedianML: Int?,
        baselineDiff: BaselineDiff?,
        userNote: String?
    ) {
        self.date = date
        self.usageHours = usageHours
        self.ahi = ahi
        self.glasgowIndex = glasgowIndex
        self.pressure95 = pressure95
        self.eprSupport = eprSupport
        self.leak95LPerMin = leak95LPerMin
        self.largeLeakPercent = largeLeakPercent
        self.timeInApneaPercent = timeInApneaPercent
        self.tidalVolumeMedianML = tidalVolumeMedianML
        self.baselineDiff = baselineDiff
        self.userNote = userNote
    }
}

/// On-device LLM output for the night-summary feature. Decoded via the
/// `@Generable` Foundation Models pipeline.
@Generable
public struct NightSummaryOutput: Codable, Hashable, Sendable {
    @Guide(description: "Headline, 3 to 5 words, no punctuation, describes the night in neutral terms.")
    public let headline: String

    @Guide(description: "One paragraph, 2 to 4 sentences, plain English, British spelling. Describe what the numbers show compared to the baseline. No advice, no recommendations, no causal claims.")
    public let paragraph: String

    public init(headline: String, paragraph: String) {
        self.headline = headline
        self.paragraph = paragraph
    }
}
