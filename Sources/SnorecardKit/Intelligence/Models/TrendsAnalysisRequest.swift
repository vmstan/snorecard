import Foundation

/// Snapshot of the Trends range the user is looking at when
/// they request a trend narrative. Passed through
/// `Library.pendingTrendsAnalysis` so `ContentView` can open
/// the summary in the macOS inspector or the iOS sheet without
/// having to reach into `TrendsView`'s local range state.
///
/// Pure data so it can flow through observable storage.
public struct TrendsAnalysisRequest: Identifiable, Equatable, Sendable {
    public let stats: [DailyStatistics]
    public let rangeStart: Date
    public let rangeEnd: Date

    public init(stats: [DailyStatistics], rangeStart: Date, rangeEnd: Date) {
        self.stats = stats
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }

    /// Stable id keyed on the range bounds and sample size.
    /// Re-tapping the button on the same range won't force a
    /// new sheet/inspector instance; moving the range picker
    /// will.
    public var id: String {
        "\(rangeStart.timeIntervalSince1970)-\(rangeEnd.timeIntervalSince1970)-\(stats.count)"
    }
}
