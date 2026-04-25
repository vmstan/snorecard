import Foundation
import Observation

/// `@MainActor` glue that owns the in-memory map of nightly summaries,
/// drives backfill against a `SleepSampleFetching` (real or mock),
/// and writes the per-day sidecars. Lives on `Library` so any view
/// can read from the same map without re-querying HealthKit.
@MainActor
@Observable
public final class HealthKitSleepCoordinator {
    /// Current best knowledge of HealthKit access. Bumped by
    /// `requestAuthorization`; views read this to decide between the
    /// "Connect" CTA and the populated card.
    public private(set) var authState: HealthKitAuthState
    /// Date-keyed map of summaries already on disk + freshly fetched.
    /// Keyed by `ResMedDay.date` (local midnight) so views can do a
    /// O(1) lookup without re-bucketing.
    public private(set) var summaryByDate: [Date: NightlySleepSummary] = [:]
    /// `(done, total)` while a backfill task is filling sidecars in,
    /// `nil` otherwise. Drives a small progress chip in the sidebar
    /// header (mirrors `cloudPrefetchProgress`).
    public private(set) var backfillProgress: (done: Int, total: Int)?
    /// `true` once the user has flipped the Settings toggle on. Owned
    /// here (not on `Library`) so the coordinator can short-circuit
    /// fetches without round-tripping through `Library` state.
    public private(set) var isEnabled: Bool

    private let fetcher: SleepSampleFetching
    private let calendar: Calendar
    /// Soft floor: don't re-query a sidecar whose `generatedAt` is
    /// fresher than this. 36 h catches Apple Watch resyncs that
    /// land late but avoids re-fetching every launch.
    private let staleAfter: TimeInterval = 36 * 60 * 60

    public init(
        fetcher: SleepSampleFetching,
        calendar: Calendar = .current,
        isEnabled: Bool = false
    ) {
        self.fetcher = fetcher
        self.calendar = calendar
        self.isEnabled = isEnabled
        self.authState = .notDetermined
    }

    /// Toggle the user-facing on/off switch. Disabling clears the
    /// in-memory map but leaves sidecars on disk so the user can flip
    /// it back on without losing history.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { summaryByDate = [:] }
    }

    /// Ask HealthKit for read access to sleep analysis. Idempotent —
    /// safe to call from both the first-launch prompt path and the
    /// Settings-toggle path.
    public func requestAuthorization() async {
        do {
            authState = try await fetcher.requestAuthorization()
        } catch {
            // Treat any framework error as "we asked, the answer
            // didn't come back" — same UI as a granted-but-no-data
            // state. We never lie about success, but a thrown error
            // here usually means the type isn't supported on this
            // device anyway.
            authState = .unsupported
        }
    }

    /// Hydrate the in-memory map from disk for the days in `card` and,
    /// when authorization is in hand and any day is missing or stale,
    /// run a single batched fetch + bucket pass to fill the gaps.
    public func attach(card: ResMedSDCard) async {
        // 1. Disk hydration — always runs, regardless of auth state.
        var loaded: [Date: NightlySleepSummary] = [:]
        for day in card.days {
            guard let folder = Self.dayFolderURL(for: day) else { continue }
            if let summary = SleepStageCache.load(for: folder) {
                loaded[day.date] = summary
            }
        }
        summaryByDate = loaded

        guard isEnabled else { return }
        // `authState` is in-memory only, so a relaunch always starts
        // at `.notDetermined` even when the user previously granted
        // access. Re-issue the request so backfill can run on launch
        // without forcing a manual "Re-sync now" tap; HealthKit
        // returns immediately without re-prompting when permissions
        // are already in place.
        if authState == .notDetermined {
            await requestAuthorization()
        }
        guard authState == .requested else { return }
        await backfill(card: card)
    }

    /// Fetch every missing/stale night for `card` in a single
    /// HealthKit query, bucket the results, and persist sidecars.
    public func backfill(card: ResMedSDCard) async {
        guard !card.days.isEmpty else { return }
        let now = Date()
        let needsUpdate: [ResMedDay] = card.days.filter { day in
            guard let existing = summaryByDate[day.date] else { return true }
            return now.timeIntervalSince(existing.generatedAt) > staleAfter
        }
        healthKitLog.info(
            "backfill: card has \(card.days.count) days, \(needsUpdate.count) need update"
        )
        guard !needsUpdate.isEmpty else { return }

        let earliest = card.days.first!.date
        let latest = card.days.last!.date
        // Pad on both sides so sleep sessions that span midnight
        // are captured fully. A `ResMedDay.date` is the recording-
        // start day at local midnight; the wake-up for that night
        // can land 30+ hours later (e.g. fell asleep 23:30 → woke
        // at 07:00 the next morning), so 24 h on the trailing side
        // is too tight. Use 48 h, and never end before the current
        // moment so an in-progress query still picks up samples
        // already written today.
        let queryStart = earliest.addingTimeInterval(-24 * 60 * 60)
        let queryEnd = max(
            latest.addingTimeInterval(48 * 60 * 60),
            Date()
        )

        backfillProgress = (done: 0, total: needsUpdate.count)
        defer { backfillProgress = nil }

        let samples: [SleepStageSample]
        do {
            samples = try await fetcher.fetchRange(
                start: queryStart,
                end: queryEnd
            )
        } catch {
            healthKitLog.error(
                "backfill: fetchRange threw — \(String(describing: error), privacy: .public)"
            )
            return
        }
        let windows = Self.cpapWindows(for: card)
        let bucketed = NightBucketing.bucketAgainstCPAPDays(
            samples: samples,
            cpapWindows: windows,
            calendar: calendar
        )
        healthKitLog.info(
            "backfill: clustered \(samples.count) samples into \(bucketed.count) day buckets across \(windows.count) CPAP windows"
        )
        for (key, bucket) in bucketed.sorted(by: { $0.key < $1.key }) {
            healthKitLog.info(
                "backfill bucket: day=\(key, privacy: .public) sampleCount=\(bucket.count)"
            )
        }

        // Folder lookup once, off the main thread cost is trivial —
        // these are URLs we already have on hand.
        var folderByDate: [Date: URL] = [:]
        for day in card.days {
            if let folder = Self.dayFolderURL(for: day) {
                folderByDate[day.date] = folder
            }
        }

        var done = 0
        for day in needsUpdate {
            done += 1
            backfillProgress = (done: done, total: needsUpdate.count)
            guard let nightSamples = bucketed[day.date],
                  !nightSamples.isEmpty else {
                // No sleep data for this night — leave any prior
                // sidecar alone (the user might have rolled back
                // permissions) but also don't drop a stub.
                continue
            }
            let summary = NightlySleepSummary.aggregate(
                nightDate: day.date,
                samples: nightSamples
            )
            summaryByDate[day.date] = summary
            if let folder = folderByDate[day.date] {
                SleepStageCache.save(summary, to: folder)
            }
        }
    }

    /// Re-query just the trailing `days` ResMed nights, used by the
    /// observer-query handler so a freshly-uploaded night lands in
    /// memory without re-fetching the full history.
    public func refreshRecent(days: Int, in card: ResMedSDCard) async {
        guard isEnabled, authState == .requested,
              !card.days.isEmpty else { return }
        let recent = Array(card.days.suffix(max(1, days)))
        let earliest = recent.first!.date
        let latest = recent.last!.date
        // Same 48 h trailing pad as `backfill` — wake-up samples
        // for the latest CPAP day land in the morning AFTER the
        // recording-start day.
        let queryStart = earliest.addingTimeInterval(-24 * 60 * 60)
        let queryEnd = max(
            latest.addingTimeInterval(48 * 60 * 60),
            Date()
        )

        let samples: [SleepStageSample]
        do {
            samples = try await fetcher.fetchRange(
                start: queryStart,
                end: queryEnd
            )
        } catch {
            return
        }
        let bucketed = NightBucketing.bucketAgainstCPAPDays(
            samples: samples,
            cpapWindows: Self.cpapWindows(for: card),
            calendar: calendar
        )
        for day in recent {
            guard let nightSamples = bucketed[day.date],
                  !nightSamples.isEmpty else { continue }
            let summary = NightlySleepSummary.aggregate(
                nightDate: day.date,
                samples: nightSamples
            )
            // Skip rewrite if nothing changed — keeps iCloud chatter
            // down on a series of no-op observer fires.
            if summaryByDate[day.date] == summary { continue }
            summaryByDate[day.date] = summary
            if let folder = Self.dayFolderURL(for: day) {
                SleepStageCache.save(summary, to: folder)
            }
        }
    }

    /// Build a `CPAPDayWindow` per ResMed day from filename timestamps
    /// plus the day's recorded `usageMinutes`. The window is padded
    /// 30 min on each side so a watch session that started slightly
    /// before mask-on (or ran past mask-off) still maps cleanly to
    /// this day. When a day has no parsed file timestamps (rare —
    /// happens during structure-only iCloud hydration), the day's
    /// own midnight is used as a stand-in start so the window still
    /// covers the calendar day.
    public static func cpapWindows(for card: ResMedSDCard) -> [NightBucketing.CPAPDayWindow] {
        let pad: TimeInterval = 30 * 60
        // Default envelope for days where we know the session
        // started but not how long it ran. 12 h covers any
        // reasonable single night without bleeding into the
        // following calendar day's window.
        let fallbackDuration: TimeInterval = 12 * 60 * 60
        return card.days.map { day in
            let start: Date = {
                if let earliest = day.files.compactMap(\.timestamp).min() {
                    return earliest
                }
                return day.date
            }()
            let usageSec = (day.stats?.usageMinutes ?? 0) * 60
            // Use the bigger of the recorded usage and the fallback —
            // a long in-bed window with little mask time still wants
            // to attract that night's watch session.
            let duration = max(usageSec, fallbackDuration)
            return NightBucketing.CPAPDayWindow(
                nightKey: day.date,
                start: start.addingTimeInterval(-pad),
                end: start.addingTimeInterval(duration + pad)
            )
        }
    }

    /// Look up the on-disk folder for a `ResMedDay`. The day's files
    /// all live in the same `DATALOG/YYYYMMDD/` directory, so the
    /// first file's parent is the canonical address. Returns `nil`
    /// when a day has no files (e.g. structure-only stub from a
    /// fresh iCloud sync) so the cache write is skipped rather than
    /// landing in a wrong place.
    public static func dayFolderURL(for day: ResMedDay) -> URL? {
        day.files.first?.url.deletingLastPathComponent()
    }
}
