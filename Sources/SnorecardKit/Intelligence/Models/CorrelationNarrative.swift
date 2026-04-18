import Foundation
import FoundationModels

/// Structured input for the correlation-narration prompt. All of
/// the statistics are pre-computed by `TagCorrelator`; the LLM only
/// turns the numeric deltas into observational prose.
public struct CorrelationNarrativeInput: Codable, Hashable, Sendable {
    public let rangeStart: Date
    public let rangeEnd: Date
    public let sampleSize: Int
    public let observations: [Observation]

    /// Single tag-vs-rest comparison. `delta` is `taggedMean − untaggedMean`
    /// in whatever unit the metric uses.
    public struct Observation: Codable, Hashable, Sendable {
        public let tag: NoteTag
        public let metric: CorrelatedMetric
        public let taggedNights: Int
        public let untaggedNights: Int
        public let taggedMean: Double
        public let untaggedMean: Double
        public let delta: Double

        public init(
            tag: NoteTag,
            metric: CorrelatedMetric,
            taggedNights: Int,
            untaggedNights: Int,
            taggedMean: Double,
            untaggedMean: Double,
            delta: Double
        ) {
            self.tag = tag
            self.metric = metric
            self.taggedNights = taggedNights
            self.untaggedNights = untaggedNights
            self.taggedMean = taggedMean
            self.untaggedMean = untaggedMean
            self.delta = delta
        }
    }

    public init(
        rangeStart: Date,
        rangeEnd: Date,
        sampleSize: Int,
        observations: [Observation]
    ) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.sampleSize = sampleSize
        self.observations = observations
    }
}

public enum CorrelatedMetric: String, Codable, Hashable, Sendable {
    case ahi
    case usageHours
    case leak95LPerMin
    case glasgowIndex
}

@Generable
public struct CorrelationNarrativeOutput: Codable, Hashable, Sendable {
    @Guide(description: "Up to 3 short bullet strings, each starting with 'On nights you noted …'. Purely observational — never say an activity 'caused', 'led to', or 'made' anything happen.")
    public let bullets: [String]

    @Guide(description: "One sentence intro, fewer than 20 words, framing the bullets as observations rather than advice.")
    public let intro: String

    public init(intro: String, bullets: [String]) {
        self.intro = intro
        self.bullets = bullets
    }
}
