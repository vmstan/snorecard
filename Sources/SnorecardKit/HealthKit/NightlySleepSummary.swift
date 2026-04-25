import Foundation

/// Per-night aggregate of Apple Watch sleep stages, pinned to the
/// matching `ResMedDay.date` (midnight in device-local time).
///
/// The raw `samples` are kept on the value because the
/// `SleepByHourChart` re-buckets stages into clock-hour windows
/// against the CPAP session timeline — recomputing those buckets
/// without sample-level resolution isn't possible from per-stage
/// totals alone.
public struct NightlySleepSummary: Codable, Sendable, Equatable {
    /// Local-midnight date that matches the `ResMedDay` this summary
    /// was bucketed onto. Lookup key for in-memory maps.
    public let nightDate: Date
    /// Earliest `inBed` (or asleep) sample timestamp for the session.
    /// Used as the "in bed at HH:MM" line in the day card.
    public let inBedStart: Date?
    /// Latest `inBed` (or asleep) sample end. Combined with
    /// `inBedStart` produces the in-bed window the card displays.
    public let inBedEnd: Date?
    public let coreSeconds: TimeInterval
    public let remSeconds: TimeInterval
    public let deepSeconds: TimeInterval
    public let awakeSeconds: TimeInterval
    public let unspecifiedSeconds: TimeInterval
    /// `core + rem + deep + unspecified`. Cached at write time so the
    /// reader doesn't drift if a future `Stage` case is added.
    public let timeAsleep: TimeInterval
    /// Envelope of the in-bed window — `inBedEnd - inBedStart`. Not
    /// the sum of `inBed`-stage records, because Apple writes
    /// overlapping blanket "in bed" rows that would double-count.
    public let timeInBed: TimeInterval
    /// All samples that fed this summary, after midnight-crossing
    /// session bucketing. Required by the hourly chart and by the
    /// "stages timeline" subtitle.
    public let samples: [SleepStageSample]
    /// When this sidecar was generated. Drives the "older than 36 h →
    /// re-fetch" check that catches late HealthKit syncs from the
    /// watch.
    public let generatedAt: Date
    /// Schema version of the on-disk payload. Bump whenever the
    /// shape changes so older sidecars can be invalidated cleanly.
    public let schemaVersion: Int

    /// Bumped from 1 → 2 when the bucketing rule changed from
    /// "Apple Health wake-up day" to "ResMed recording-start day with
    /// CPAP-window overlap". Sidecars written under v1 are dropped on
    /// load so the next attach() rebuilds them with the new rule.
    public static let currentSchemaVersion = 2

    public init(
        nightDate: Date,
        inBedStart: Date?,
        inBedEnd: Date?,
        coreSeconds: TimeInterval,
        remSeconds: TimeInterval,
        deepSeconds: TimeInterval,
        awakeSeconds: TimeInterval,
        unspecifiedSeconds: TimeInterval,
        samples: [SleepStageSample],
        generatedAt: Date = Date(),
        schemaVersion: Int = NightlySleepSummary.currentSchemaVersion
    ) {
        self.nightDate = nightDate
        self.inBedStart = inBedStart
        self.inBedEnd = inBedEnd
        self.coreSeconds = coreSeconds
        self.remSeconds = remSeconds
        self.deepSeconds = deepSeconds
        self.awakeSeconds = awakeSeconds
        self.unspecifiedSeconds = unspecifiedSeconds
        self.timeAsleep = coreSeconds + remSeconds + deepSeconds + unspecifiedSeconds
        self.timeInBed = {
            guard let inBedStart, let inBedEnd, inBedEnd > inBedStart else {
                return coreSeconds + remSeconds + deepSeconds + unspecifiedSeconds + awakeSeconds
            }
            return inBedEnd.timeIntervalSince(inBedStart)
        }()
        self.samples = samples
        self.generatedAt = generatedAt
        self.schemaVersion = schemaVersion
    }

    /// Aggregate a list of `SleepStageSample`s already bucketed onto
    /// a single ResMed night into the on-disk summary shape. Pure
    /// function so the importer / fetcher / tests share one
    /// implementation.
    public static func aggregate(
        nightDate: Date,
        samples: [SleepStageSample],
        generatedAt: Date = Date()
    ) -> NightlySleepSummary {
        var core: TimeInterval = 0
        var rem: TimeInterval = 0
        var deep: TimeInterval = 0
        var awake: TimeInterval = 0
        var unspecified: TimeInterval = 0
        var inBedStart: Date?
        var inBedEnd: Date?
        for sample in samples {
            switch sample.stage {
            case .core: core += sample.duration
            case .rem: rem += sample.duration
            case .deep: deep += sample.duration
            case .awake: awake += sample.duration
            case .asleepUnspecified: unspecified += sample.duration
            case .inBed:
                inBedStart = min(inBedStart ?? sample.start, sample.start)
                inBedEnd = max(inBedEnd ?? sample.end, sample.end)
            }
        }
        // Fall back to the asleep envelope if the source didn't
        // emit any explicit `.inBed` rows (third-party trackers
        // sometimes skip them).
        if inBedStart == nil || inBedEnd == nil {
            let asleep = samples.filter { $0.isAsleep }
            inBedStart = asleep.map(\.start).min()
            inBedEnd = asleep.map(\.end).max()
        }
        return NightlySleepSummary(
            nightDate: nightDate,
            inBedStart: inBedStart,
            inBedEnd: inBedEnd,
            coreSeconds: core,
            remSeconds: rem,
            deepSeconds: deep,
            awakeSeconds: awake,
            unspecifiedSeconds: unspecified,
            samples: samples,
            generatedAt: generatedAt
        )
    }

    /// Fraction of `timeAsleep` spent in `stage`. Returns `0` when
    /// the night has no asleep time so trend averages can include
    /// the night with a defined-but-zero value rather than a NaN.
    public func fractionAsleep(in stage: SleepStageSample.Stage) -> Double {
        guard timeAsleep > 0 else { return 0 }
        switch stage {
        case .core: return coreSeconds / timeAsleep
        case .rem: return remSeconds / timeAsleep
        case .deep: return deepSeconds / timeAsleep
        case .asleepUnspecified: return unspecifiedSeconds / timeAsleep
        case .awake, .inBed: return 0
        }
    }
}
