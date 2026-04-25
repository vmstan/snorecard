import Foundation

/// One contiguous Apple Watch (or third-party) sleep-stage record as
/// reported by HealthKit's `HKCategoryTypeIdentifier.sleepAnalysis`.
/// Stored shape — purposely framework-free so the value can ride the
/// JSON sidecar and be tested without `import HealthKit`.
public struct SleepStageSample: Codable, Sendable, Equatable, Identifiable {
    /// Mapped from `HKCategoryValueSleepAnalysis`. The legacy
    /// `.asleep` value (deprecated in iOS 16) is folded into
    /// `asleepUnspecified` on decode so old watchOS rows still
    /// participate in totals without a parallel case.
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case inBed
        case awake
        case core
        case rem
        case deep
        case asleepUnspecified
    }

    /// Stable identity — `(start, end, stage)` is unique enough for an
    /// in-memory list, matching how HealthKit deduplicates writers'
    /// rows. Not used for storage; the sidecar is the source of truth.
    public var id: String {
        "\(stage.rawValue)|\(start.timeIntervalSinceReferenceDate)|\(end.timeIntervalSinceReferenceDate)"
    }

    public let stage: Stage
    public let start: Date
    public let end: Date
    /// Bundle ID of the sample's source. Captured so a future filter
    /// (e.g. "Apple Watch only") can drop third-party trackers without
    /// re-querying HealthKit.
    public let sourceBundleID: String

    public init(stage: Stage, start: Date, end: Date, sourceBundleID: String) {
        self.stage = stage
        self.start = start
        self.end = end
        self.sourceBundleID = sourceBundleID
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// True for the three "real sleep" stages — what the per-night
    /// totals and the hourly stacked chart treat as asleep time.
    public var isAsleep: Bool {
        switch stage {
        case .core, .rem, .deep, .asleepUnspecified: return true
        case .inBed, .awake: return false
        }
    }
}
