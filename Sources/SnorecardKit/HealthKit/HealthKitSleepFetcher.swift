import Foundation
import os.log
#if canImport(HealthKit)
import HealthKit
#endif

/// Subsystem used by every HealthKit-related log line so a user can
/// stream just these via `log stream --predicate 'subsystem ==
/// "com.vmstan.Snorecard" && category == "HealthKit"'`. Diagnostic
/// only — verbose by design while we're sorting out macOS HealthKit
/// coverage gaps. Move to `.debug` once stable.
let healthKitLog = Logger(subsystem: "com.vmstan.Snorecard", category: "HealthKit")

/// Async-friendly façade over `HKSampleQuery` / `HKObserverQuery` for
/// the one HealthKit type Snorecard reads — sleep-stage analysis.
///
/// Conformance is split through `SleepSampleFetching` so the
/// coordinator (and its tests) can be exercised against a mock
/// without `import HealthKit`. The real implementation lives below
/// the `canImport(HealthKit)` gate; on platforms without the
/// framework, only the protocol vends — keeps `SnorecardKit` Linux-
/// buildable for CI.
public protocol SleepSampleFetching: Sendable {
    /// Bring HealthKit into a known state. Calls
    /// `HKHealthStore.requestAuthorization` once and returns the
    /// resulting `HealthKitAuthState`. Apple intentionally hides
    /// read-grant outcomes; the returned state only tells the caller
    /// whether the system completed the prompt.
    func requestAuthorization() async throws -> HealthKitAuthState

    /// Fetch every sleep-analysis sample in `[start, end)`.
    /// Single round-trip; HealthKit pages internally. Sorted by
    /// `start` ascending so the bucketing pass can stream.
    func fetchRange(start: Date, end: Date) async throws -> [SleepStageSample]
}

public enum HealthKitSleepError: Error, Sendable {
    /// HealthKit isn't available on this device at all.
    case unsupported
    /// Wraps any framework-thrown error so callers can display the
    /// underlying reason without conditionally importing HealthKit.
    case framework(String)
}

#if canImport(HealthKit)

/// Production fetcher backed by `HKHealthStore`.
public actor HealthKitSleepFetcher: SleepSampleFetching {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public func requestAuthorization() async throws -> HealthKitAuthState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unsupported }
        let type = HKCategoryType(.sleepAnalysis)
        do {
            try await store.requestAuthorization(toShare: [], read: [type])
            return .requested
        } catch {
            throw HealthKitSleepError.framework(String(describing: error))
        }
    }

    public func fetchRange(start: Date, end: Date) async throws -> [SleepStageSample] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSleepError.unsupported
        }
        let type = HKCategoryType(.sleepAnalysis)
        healthKitLog.info(
            "fetchRange query: start=\(start, privacy: .public) end=\(end, privacy: .public)"
        )
        // Composing a date predicate inside `HKSamplePredicate
        // .categorySample(type:predicate:)` was returning only one
        // sample on iOS even when HealthKit had hundreds within the
        // window — the typed-predicate composition silently filters
        // most multi-source data out. Workaround: query newest-first
        // with no date predicate (a generous descending-sorted
        // window) and filter to `[start, end]` in Swift. The cost is
        // O(N) over the most recent few thousand samples, which is
        // cheap and well below the 14 days × ~100 stages/night the
        // user's data set produces.
        //
        // The hard cap is sized for a worst-case heavy user (Sleep
        // Schedule + watch + AutoSleep × multiple devices) writing
        // ~300 samples/night for the longest range we'd query
        // (typically 14 days, sometimes a year for trends), which
        // tops out around ~100k samples but realistically is well
        // under 10k for a typical user. 50k is safely above that
        // and below any plausible memory concern.
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 50_000
        )
        let allRecent: [HKCategorySample]
        do {
            allRecent = try await descriptor.result(for: store)
        } catch {
            healthKitLog.error(
                "fetchRange failed: \(String(describing: error), privacy: .public)"
            )
            throw HealthKitSleepError.framework(String(describing: error))
        }
        // Filter in Swift — the descriptor's typed-predicate path is
        // unreliable; this loop is fast and observable.
        let raw = allRecent.filter { sample in
            sample.startDate >= start && sample.startDate < end
        }
        let rawCount = raw.count
        let mapped = raw.compactMap(Self.map(_:))
        let dropped = rawCount - mapped.count
        let firstStart = mapped.last.map { $0.start.description } ?? "nil"
        let lastEnd = mapped.first.map { $0.end.description } ?? "nil"
        var hist: [String: Int] = [:]
        for s in mapped {
            hist[s.stage.rawValue, default: 0] += 1
        }
        let histStr = hist.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let sources = Set(mapped.map(\.sourceBundleID))
        healthKitLog.info(
            "fetchRange returned scanned=\(allRecent.count) inRange=\(rawCount) mapped=\(mapped.count) dropped=\(dropped) firstStart=\(firstStart, privacy: .public) lastEnd=\(lastEnd, privacy: .public) stages=[\(histStr, privacy: .public)] sources=\(sources.count)"
        )
        for source in sources {
            healthKitLog.info("fetchRange source: \(source, privacy: .public)")
        }
        // Re-sort ascending for the bucketing pass, which expects
        // chronological order so its session-clustering walk is
        // monotonic.
        return mapped.sorted { $0.start < $1.start }
    }

    /// Long-running observer so a new night that lands on the watch
    /// while the app is open re-bucketed into the in-memory map.
    /// The handler is invoked with the date the observer last fired
    /// (always `Date()` — there's no per-sample resolution at the
    /// `HKObserverQuery` layer; coordinators interpret this as
    /// "re-query recent days").
    @discardableResult
    public func startObserving(
        _ handler: @Sendable @escaping (Date) -> Void
    ) async throws -> HKObserverQuery {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSleepError.unsupported
        }
        let type = HKCategoryType(.sleepAnalysis)
        let observer = HKObserverQuery(
            sampleType: type,
            predicate: nil
        ) { _, completion, _ in
            handler(Date())
            completion()
        }
        store.execute(observer)
        #if os(iOS)
        // Background delivery on the watch's own cadence — iOS only.
        // Errors are non-fatal (background delivery isn't load-bearing
        // for foreground use); log via the framework-error path so
        // callers can surface them if they care.
        try? await store.enableBackgroundDelivery(
            for: type,
            frequency: .immediate
        )
        #endif
        return observer
    }

    public func stopObserving(_ query: HKObserverQuery) {
        store.stop(query)
    }

    /// Map an `HKCategorySample` to our framework-free shape. Returns
    /// `nil` for category values we don't recognise so a future Apple
    /// addition (more granular stages, etc.) lands as an explicit drop
    /// rather than a wrong stage.
    private static func map(_ sample: HKCategorySample) -> SleepStageSample? {
        let stage: SleepStageSample.Stage
        switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
        case .inBed: stage = .inBed
        case .awake: stage = .awake
        case .asleepCore: stage = .core
        case .asleepREM: stage = .rem
        case .asleepDeep: stage = .deep
        case .asleepUnspecified: stage = .asleepUnspecified
        case .asleep:
            // Deprecated in iOS 16. Old watchOS rows still report it;
            // fold them into `asleepUnspecified` so totals are intact.
            stage = .asleepUnspecified
        default: return nil
        }
        return SleepStageSample(
            stage: stage,
            start: sample.startDate,
            end: sample.endDate,
            sourceBundleID: sample.sourceRevision.source.bundleIdentifier
        )
    }
}

#endif
