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

extension MetricExplainInput {
    /// Plain-English rendering for embedding in the prompt.
    public var promptDescription: String {
        var lines: [String] = []
        lines.append("Metric: \(metric.displayLabel)")
        lines.append("Your current value: \(Self.formatValue(currentValue, metric: metric)) \(unitLabel)")
        if let mean = recent14DayMean {
            lines.append("Your 14-day mean: \(Self.formatValue(mean, metric: metric)) \(unitLabel)")
        }
        if let p90 = recent14DayP90 {
            lines.append("Your 14-day 90th percentile: \(Self.formatValue(p90, metric: metric)) \(unitLabel)")
        }
        if let goodMax = norms.goodMax {
            lines.append("Boundary for \"good\": up to \(Self.formatValue(goodMax, metric: metric)) \(unitLabel)")
        }
        if let elevatedMax = norms.elevatedMax {
            lines.append("Boundary for \"elevated\": up to \(Self.formatValue(elevatedMax, metric: metric)) \(unitLabel)")
        }
        var body = lines.map { "- \($0)" }.joined(separator: "\n")
        body += "\n\nContext for the metric:\n\(norms.description)"
        return body
    }

    private static func formatValue(_ value: Double, metric: ExplainableMetric) -> String {
        switch metric {
        case .largeLeak:     return String(format: "%.1f", value)
        case .leak95:        return String(format: "%.0f", value)
        case .tidalVolume:   return String(format: "%.0f", value)
        case .glasgowIndex:  return String(format: "%.2f", value)
        default:             return String(format: "%.1f", value)
        }
    }
}

extension ExplainableMetric {
    /// Human-friendly label for the metric. Matches the card
    /// titles used in `DayDetailView` so the model never sees
    /// an enum raw value like "pressure95" in the prompt.
    public var displayLabel: String {
        switch self {
        case .ahi:          return "AHI"
        case .glasgowIndex: return "Glasgow Index"
        case .pressure95:   return "Pressure (95th percentile target EPAP)"
        case .epr:          return "Pressure support (IPAP − EPAP)"
        case .leak95:       return "Leak (95th percentile)"
        case .largeLeak:    return "Large leak (percent of usage)"
        case .tidalVolume:  return "Tidal volume (median)"
        }
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
