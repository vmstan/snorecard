import Foundation

/// Pure functions that group raw `SleepStageSample`s into nightly
/// sessions and bucket each session onto a ResMed-day key. Kept
/// HealthKit-free so they can be tested on any platform.
public enum NightBucketing {
    /// Maximum gap between adjacent samples that's still considered
    /// the same sleep session. Bathroom breaks rarely exceed 90 min;
    /// next-day naps almost always do.
    public static let sessionGap: TimeInterval = 90 * 60

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

    /// The calendar-day "night key" a session belongs to: midnight of
    /// the day on which the session's mid-asleep timestamp falls.
    /// Matches what the iOS Health app shows — the night a session
    /// "belongs to" is the date the user woke up.
    public static func nightKey(
        for session: [SleepStageSample],
        calendar: Calendar = .current
    ) -> Date? {
        let asleep = session.filter(\.isAsleep)
        let pool = asleep.isEmpty ? session : asleep
        guard !pool.isEmpty else { return nil }
        let earliest = pool.map(\.start).min()!
        let latest = pool.map(\.end).max()!
        let mid = Date(
            timeIntervalSince1970: (earliest.timeIntervalSince1970
                + latest.timeIntervalSince1970) / 2
        )
        return calendar.startOfDay(for: mid)
    }

    /// Cluster + bucket in one pass: returns `[nightKey: samples]`
    /// where `samples` is the longest session that landed on that
    /// date. Sessions that don't yield a night key (no asleep, no
    /// in-bed) are dropped silently. When two sessions land on the
    /// same date (true nap + main night), the longer wins so the
    /// per-night card never double-counts.
    public static func bucketByNight(
        samples: [SleepStageSample],
        calendar: Calendar = .current,
        gap: TimeInterval = sessionGap
    ) -> [Date: [SleepStageSample]] {
        var out: [Date: [SleepStageSample]] = [:]
        for session in sessions(from: samples, gap: gap) {
            guard let key = nightKey(for: session, calendar: calendar) else {
                continue
            }
            let existing = out[key] ?? []
            if sessionDuration(session) > sessionDuration(existing) {
                out[key] = session
            }
        }
        return out
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
}
