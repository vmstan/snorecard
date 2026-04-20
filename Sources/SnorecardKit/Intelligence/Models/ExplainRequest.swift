import Foundation

/// Describes a user's tap on a stat card to open an on-device
/// metric explanation. Carries enough data for the sheet/inspector
/// view to render its chrome (`displayLabel`, `displayValue`,
/// `valueCaption`) plus a `source` that tells `Library` which
/// async resolver to dispatch to.
///
/// Kept as pure data (no closures) so it can flow through
/// observable state and across actor boundaries without fuss.
public struct ExplainRequest: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// Tapped on a per-night stat card — `dayID` is the
        /// `ResMedDay.id` so the resolver can locate the day
        /// inside the currently-loaded card.
        case day(dayID: Date)
        /// Tapped on an Overview card — the aggregate is already
        /// computed, so the request carries both the value and
        /// the range it was computed over.
        case overview(
            averageValue: Double,
            rangeStart: Date,
            rangeEnd: Date,
            sampleSize: Int
        )
    }

    public let metric: ExplainableMetric
    /// Title rendered at the top of the sheet / inspector.
    public let displayLabel: String
    /// Headline value shown inside the sheet's body, matching
    /// the number the user saw on the card they tapped.
    public let displayValue: String
    /// Caption below the headline value — e.g. "Your value for
    /// this night" vs. "Your average for this range".
    public let valueCaption: String
    public let source: Source

    public init(
        metric: ExplainableMetric,
        displayLabel: String,
        displayValue: String,
        valueCaption: String,
        source: Source
    ) {
        self.metric = metric
        self.displayLabel = displayLabel
        self.displayValue = displayValue
        self.valueCaption = valueCaption
        self.source = source
    }

    public var id: String {
        switch source {
        case .day(let dayID):
            return "day-\(metric.rawValue)-\(dayID.timeIntervalSince1970)"
        case .overview(_, let start, let end, _):
            return "overview-\(metric.rawValue)-\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)"
        }
    }
}
