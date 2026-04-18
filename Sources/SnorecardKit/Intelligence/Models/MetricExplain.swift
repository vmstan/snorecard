import Foundation
import FoundationModels

/// Metrics that support the tap-to-explain affordance on the daily
/// view. The enum is closed so the prompt and the view layer agree
/// on which explanations exist.
public enum ExplainableMetric: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case ahi
    case glasgowIndex
    case pressure95
    case epr
    case leak95
    case largeLeak
    case tidalVolume

    public var id: String { rawValue }
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
        recent14DayP90: Double?
    ) {
        self.metric = metric
        self.currentValue = currentValue
        self.unitLabel = unitLabel
        self.norms = norms
        self.recent14DayMean = recent14DayMean
        self.recent14DayP90 = recent14DayP90
    }
}

@Generable
public struct MetricExplainOutput: Codable, Hashable, Sendable {
    @Guide(description: "1 or 2 sentences defining what the metric represents. Plain English. Do not repeat the user's numeric value here.")
    public let whatItMeans: String

    @Guide(description: "1 or 2 sentences putting the user's current value in context compared to the provided norms and recent mean. No advice, no recommendations, no causal verbs.")
    public let howYoursLooks: String

    public init(whatItMeans: String, howYoursLooks: String) {
        self.whatItMeans = whatItMeans
        self.howYoursLooks = howYoursLooks
    }
}
