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

extension CorrelationNarrativeInput {
    /// Plain-English rendering for embedding in the prompt.
    public var promptDescription: String {
        var lines: [String] = []
        lines.append("Range: \(Self.rangeFormatter.string(from: rangeStart)) to \(Self.rangeFormatter.string(from: rangeEnd))")
        lines.append("Sample size: \(sampleSize) nights with data")
        var body = lines.map { "- \($0)" }.joined(separator: "\n")
        body += "\n\nObservations (already computed — narrate these, do not invent new ones):"
        for obs in observations {
            let taggedFmt = Self.formatValue(obs.taggedMean, metric: obs.metric)
            let untaggedFmt = Self.formatValue(obs.untaggedMean, metric: obs.metric)
            let unit = Self.unit(for: obs.metric)
            body += """

            - Tag: \(obs.tag.displayLabel)
              Metric: \(Self.metricLabel(obs.metric))
              On \(obs.taggedNights) tagged night(s), average \(taggedFmt)\(unit)
              On \(obs.untaggedNights) untagged night(s), average \(untaggedFmt)\(unit)
            """
        }
        return body
    }

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static func formatValue(_ value: Double, metric: CorrelatedMetric) -> String {
        switch metric {
        case .ahi:              return String(format: "%.1f", value)
        case .usageHours:       return String(format: "%.1f", value)
        case .leak95LPerMin:    return String(format: "%.0f", value)
        case .glasgowIndex:     return String(format: "%.2f", value)
        }
    }

    private static func unit(for metric: CorrelatedMetric) -> String {
        switch metric {
        case .ahi:              return " events/hr"
        case .usageHours:       return " hours"
        case .leak95LPerMin:    return " L/min"
        case .glasgowIndex:     return ""
        }
    }

    private static func metricLabel(_ metric: CorrelatedMetric) -> String {
        switch metric {
        case .ahi:              return "AHI"
        case .usageHours:       return "Usage hours"
        case .leak95LPerMin:    return "Leak (95th percentile)"
        case .glasgowIndex:     return "Glasgow Index"
        }
    }
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
