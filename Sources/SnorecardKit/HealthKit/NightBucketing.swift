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
    /// overlap**. For each clustered watch session, picks the
    /// `CPAPDayWindow` that overlaps the most. When no window
    /// overlaps (the user wore the watch but didn't use CPAP that
    /// night), falls back to the session-start calendar day so the
    /// data still lands on a meaningful date.
    ///
    /// Longest-watch-session-wins on collisions, matching the
    /// older `bucketByNight` behaviour so a daytime nap never
    /// displaces a night's main session.
    public static func bucketAgainstCPAPDays(
        samples: [SleepStageSample],
        cpapWindows: [CPAPDayWindow],
        calendar: Calendar = .current,
        gap: TimeInterval = sessionGap
    ) -> [Date: [SleepStageSample]] {
        var out: [Date: [SleepStageSample]] = [:]
        for session in sessions(from: samples, gap: gap) {
            guard let key = bestKey(
                for: session,
                cpapWindows: cpapWindows,
                calendar: calendar
            ) else { continue }
            let existing = out[key] ?? []
            if sessionDuration(session) > sessionDuration(existing) {
                out[key] = session
            }
        }
        return out
    }

    /// Pick the night key for a single clustered session: maximal
    /// CPAP-window overlap if any window overlaps, otherwise the
    /// session-start calendar date.
    private static func bestKey(
        for session: [SleepStageSample],
        cpapWindows: [CPAPDayWindow],
        calendar: Calendar
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
        if bestOverlap > 0 { return bestKey }
        return nightKey(for: session, calendar: calendar)
    }

    /// Older bucketing entry point — kept for callers that don't
    /// have CPAP windows in hand. Buckets by `nightKey` (session-
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
