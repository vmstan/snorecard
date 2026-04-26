import Foundation
import os.log
#if canImport(HealthKit)
import HealthKit
#endif

/// Subsystem used by every HealthKit-related log line. Stream via
/// `log stream --predicate 'subsystem == "com.vmstan.Snorecard" &&
/// category == "HealthKit"' --level debug`. Operational lines log
/// at `.error` (fetch failures); per-fetch headlines at `.debug` so
/// they're elided in release builds.
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

    /// Begin observing new sleep-analysis samples and enable
    /// HealthKit background delivery so the OS wakes the app
    /// when the watch posts a new night. The handler receives a
    /// `done` closure that **must** be invoked once the async
    /// follow-up work has finished — iOS revokes background
    /// delivery for handlers that don't acknowledge events
    /// promptly. Calling this method twice is a no-op so
    /// callers can re-invoke after relaunch without bookkeeping.
    func startObserving(
        _ handler: @Sendable @escaping (@Sendable @escaping () -> Void) -> Void
    ) async throws

    /// Tear down the active observer (if any) and disable
    /// background delivery. Safe to call when nothing is
    /// observed.
    func stopObserving() async
}

public enum HealthKitSleepError: Error, Sendable {
    /// HealthKit isn't available on this device at all.
    case unsupported
    /// Wraps any framework-thrown error so callers can display the
    /// underlying reason without conditionally importing HealthKit.
    case framework(String)
}

#if canImport(HealthKit)

/// Bridges HealthKit's non-`@Sendable` completion handler into a
/// `@Sendable` closure so the observer-query callback can hand it
/// off to async tails. Apple's `HKObserverQueryCompletionHandler`
/// is documented as safe to invoke from any thread; the lack of
/// `@Sendable` on the typealias is purely an annotation gap.
private struct UncheckedSendableCompletion: @unchecked Sendable {
    let invoke: () -> Void
    init(_ block: @escaping () -> Void) { self.invoke = block }
    func callAsFunction() { invoke() }
}

/// Production fetcher backed by `HKHealthStore`.
public actor HealthKitSleepFetcher: SleepSampleFetching {
    private let store: HKHealthStore
    /// Currently-active observer query, retained so we can
    /// `stop` it on tear-down. `nil` when not observing — also
    /// the "is observing?" gate that makes `startObserving`
    /// idempotent across relaunches.
    private var observerQuery: HKObserverQuery?

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
        // Composing a date predicate inside `HKSamplePredicate
        // .categorySample(type:predicate:)` returned only one sample
        // on iOS 26 even when HealthKit had many in the window — the
        // typed-predicate composition silently filters multi-source
        // data out. Workaround: query newest-first with no date
        // predicate and filter to `[start, end]` in Swift. The cap
        // is sized for a worst-case heavy user (Sleep Schedule +
        // watch + AutoSleep × multiple devices) over the longest
        // range we'd query, well above what any realistic user
        // produces and well below any plausible memory concern.
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
        let inRange = allRecent.filter { sample in
            sample.startDate >= start && sample.startDate < end
        }
        let mapped = inRange.compactMap(Self.map(_:))
        healthKitLog.debug(
            "fetchRange scanned=\(allRecent.count) inRange=\(inRange.count) mapped=\(mapped.count)"
        )
        // Re-sort ascending for the bucketing pass, which expects
        // chronological order so its session-clustering walk is
        // monotonic.
        return mapped.sorted { $0.start < $1.start }
    }

    /// Register an `HKObserverQuery` for sleep-analysis and turn
    /// on background delivery (iOS only). When HealthKit reports
    /// new samples the handler runs with a `done` closure it must
    /// invoke once any follow-up work completes — iOS revokes
    /// background delivery for apps that don't ack events. The
    /// caller should NOT call `done` directly inside the handler
    /// if it spawns async work; instead capture and call it from
    /// the async tail.
    ///
    /// Idempotent: a second invocation is a no-op so the
    /// coordinator can call this both at app launch and after
    /// a card load without bookkeeping.
    public func startObserving(
        _ handler: @Sendable @escaping (@Sendable @escaping () -> Void) -> Void
    ) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSleepError.unsupported
        }
        if observerQuery != nil { return }
        let type = HKCategoryType(.sleepAnalysis)
        let observer = HKObserverQuery(
            sampleType: type,
            predicate: nil
        ) { _, completion, _ in
            // HealthKit's completion handler isn't typed `@Sendable`
            // even though it's safe to call from any actor; wrap it
            // in an unchecked-Sendable box so the caller's async tail
            // can invoke it once the follow-up work finishes.
            let boxed = UncheckedSendableCompletion(completion)
            handler { boxed.callAsFunction() }
        }
        store.execute(observer)
        observerQuery = observer
        #if os(iOS)
        // Background delivery on the watch's own cadence — iOS only.
        // Errors are non-fatal (background delivery isn't load-bearing
        // for foreground use); the observer still fires while the
        // app is open even if this fails.
        do {
            try await store.enableBackgroundDelivery(
                for: type,
                frequency: .immediate
            )
            healthKitLog.info("background delivery enabled for sleep analysis")
        } catch {
            healthKitLog.error(
                "enableBackgroundDelivery failed: \(String(describing: error), privacy: .public)"
            )
        }
        #endif
    }

    public func stopObserving() async {
        if let query = observerQuery {
            store.stop(query)
            observerQuery = nil
        }
        #if os(iOS)
        let type = HKCategoryType(.sleepAnalysis)
        do {
            try await store.disableBackgroundDelivery(for: type)
            healthKitLog.debug("background delivery disabled")
        } catch {
            // Non-fatal — disabling can fail if it was never
            // enabled in this process.
        }
        #endif
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
