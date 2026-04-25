import Foundation

/// Pure functions that group raw `SleepStageSample`s into nightly
/// sessions and bucket each session onto a ResMed-day key. Kept
/// HealthKit-free so they can be tested on any platform.
public enum NightBucketing {
    /// Maximum gap between adjacent samples that's still considered
    /// the same sleep session. Bathroom breaks rarely exceed 90 min;
    /// next-day naps almost always do.
    public static let sessionGap: TimeInterval = 90 * 60

    /// Time window of one ResMed CPAP recording — used to decide
    /// which day a watch sleep session belongs to. ResMed buckets
    /// each recording by its start day in device-local time, which
    /// doesn't match Apple Health's wake-up-day convention. Pairing
    /// watch sessions with CPAP windows by overlap makes the two
    /// agree on which night is which.
    public struct CPAPDayWindow: Sendable, Equatable {
        /// Matches `ResMedDay.date` — local midnight of the recording's
        /// start day, which is the dictionary key the coordinator
        /// stores summaries under.
        public let nightKey: Date
        /// Wall-clock start of the CPAP session window. Padded
        /// before the actual mask-on time so a watch session that
        /// began slightly earlier still maps to this day.
        public let start: Date
        /// Wall-clock end of the CPAP session window. Padded after
        /// the actual mask-off time for the same reason.
        public let end: Date

        public init(nightKey: Date, start: Date, end: Date) {
            self.nightKey = nightKey
            self.start = start
            self.end = end
        }
    }

    /// Cluster a sorted-by-`start` sample list into sessions, splitting
    /// whenever there's no sample within `sessionGap` of the previous
    /// one's `end`.
    public static func sessions(
        from samples: [SleepStageSample],
        gap: TimeInterval = sessionGap
    ) -> [[SleepStageSample]] {
        guard !samples.isEmpty else { return [] }
        let sorted = samples.sorted { $0.start < $1.start }
        var sessions: [[SleepStageSample]] = []
        var current: [SleepStageSample] = [sorted[0]]
        var currentEnd = sorted[0].end
        for sample in sorted.dropFirst() {
            if sample.start.timeIntervalSince(currentEnd) > gap {
                sessions.append(current)
                current = [sample]
            } else {
                current.append(sample)
            }
            currentEnd = max(currentEnd, sample.end)
        }
        sessions.append(current)
        return sessions
    }

    /// Calendar-day key for a session, used as the fallback when no
    /// CPAP window overlaps the watch session. Returns midnight of
    /// the day on which the session **started** so it matches ResMed's
    /// recording-start-day folder convention (a 23:45 → 06:30 session
    /// belongs to the day the user went to bed, not the day they
    /// woke up).
    public static func nightKey(
        for session: [SleepStageSample],
        calendar: Calendar = .current
    ) -> Date? {
        guard !session.isEmpty else { return nil }
        let earliest = session.map(\.start).min()!
        return calendar.startOfDay(for: earliest)
    }

    /// Total asleep + in-bed seconds covered by a session — the metric
    /// used to pick a winner when two sessions collide on the same
    /// night key.
    public static func sessionDuration(_ session: [SleepStageSample]) -> TimeInterval {
        guard !session.isEmpty else { return 0 }
        let earliest = session.map(\.start).min()!
        let latest = session.map(\.end).max()!
        return latest.timeIntervalSince(earliest)
    }

    /// Bucket watch sessions onto ResMed days by **CPAP recording
    /// overlap**. Each clustered watch session is matched to the
    /// `CPAPDayWindow` it overlaps the most. **All clusters that
    /// match the same CPAP day are accumulated together** so a night
    /// the watch split into several sessions (bathroom break, brief
    /// wake-up, etc.) still produces one combined summary for that
    /// CPAP day. When a cluster doesn't overlap any window — usually
    /// a daytime nap on a day with no CPAP recording — it falls
    /// back to the session-start calendar day with longest-wins so
    /// a 20-minute nap never displaces an existing main session
    /// on a no-CPAP day.
    public static func bucketAgainstCPAPDays(
        samples: [SleepStageSample],
        cpapWindows: [CPAPDayWindow],
        calendar: Calendar = .current,
        gap: TimeInterval = sessionGap
    ) -> [Date: [SleepStageSample]] {
        var out: [Date: [SleepStageSample]] = [:]
        for session in sessions(from: samples, gap: gap) {
            let match = matchedCPAPDay(for: session, in: cpapWindows)
            if let matchedKey = match {
                // CPAP-overlap match → accumulate. Multiple clusters
                // from the same night all belong together; keeping
                // only the longest would drop bathroom-break splits
                // and produce a per-night summary that's missing
                // half the user's sleep.
                out[matchedKey, default: []].append(contentsOf: session)
            } else {
                // No CPAP overlap → fall back to session-start day
                // with longest-wins, so a daytime nap doesn't pollute
                // a day that already has a longer no-CPAP session.
                guard let fallbackKey = nightKey(
                    for: session, calendar: calendar
                ) else { continue }
                let existing = out[fallbackKey] ?? []
                if sessionDuration(session) > sessionDuration(existing) {
                    out[fallbackKey] = session
                }
            }
        }
        return out
    }

    /// Return the CPAP day key whose window has maximal overlap
    /// with this clustered session, or `nil` if no window overlaps.
    private static func matchedCPAPDay(
        for session: [SleepStageSample],
        in cpapWindows: [CPAPDayWindow]
    ) -> Date? {
        guard !session.isEmpty else { return nil }
        let watchStart = session.map(\.start).min()!
        let watchEnd = session.map(\.end).max()!

        var bestKey: Date?
        var bestOverlap: TimeInterval = 0
        for window in cpapWindows {
            let lower = max(watchStart, window.start)
            let upper = min(watchEnd, window.end)
            let overlap = max(0, upper.timeIntervalSince(lower))
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestKey = window.nightKey
            }
        }
        return bestOverlap > 0 ? bestKey : nil
    }

    /// Older bucketing entry point — kept for callers that don't
    /// have CPAP windows in hand. With no windows every cluster
    /// hits the fallback path, which buckets by `nightKey` (session-
    /// start day) and picks the longest session per key.
    public static func bucketByNight(
        samples: [SleepStageSample],
        calendar: Calendar = .current,
        gap: TimeInterval = sessionGap
    ) -> [Date: [SleepStageSample]] {
        bucketAgainstCPAPDays(
            samples: samples,
            cpapWindows: [],
            calendar: calendar,
            gap: gap
        )
    }
}
