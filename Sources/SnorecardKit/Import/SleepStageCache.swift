import Foundation

/// Per-day sidecar persistence for `NightlySleepSummary`. Sits next
/// to `.snorecard-stats.json` / `.snorecard-notes.json` inside each
/// `DATALOG/YYYYMMDD/` folder so it rides the same iCloud Drive sync
/// as everything else and a fresh device gets its sleep history for
/// free without re-prompting HealthKit.
public enum SleepStageCache {

    /// Filename used for the sidecar inside every day folder.
    public static let filename = ".snorecard-sleep.json"

    /// Read the cached summary for a day folder, or `nil` if no
    /// sidecar exists, the file can't be decoded, or its
    /// `schemaVersion` is from the future. Future-version reads are
    /// dropped so a build that doesn't understand the payload
    /// can't surface partial / wrong data.
    public static func load(for dayFolder: URL) -> NightlySleepSummary? {
        let url = dayFolder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let summary = try? decoder.decode(NightlySleepSummary.self, from: data),
              summary.schemaVersion <= NightlySleepSummary.currentSchemaVersion
        else { return nil }
        return summary
    }

    /// Write the sidecar atomically. `nil` deletes any existing file
    /// — used by the toggle-off / re-sync paths so iCloud doesn't
    /// keep stale sleep payloads after the user revokes access.
    public static func save(_ summary: NightlySleepSummary?, to dayFolder: URL) {
        let url = dayFolder.appendingPathComponent(filename)
        let fm = FileManager.default
        guard let summary else {
            try? fm.removeItem(at: url)
            return
        }
        guard let data = try? encoder.encode(summary) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Delete the sidecar if present. Convenience for the bulk
    /// "purge all sleep sidecars" path triggered from Settings.
    public static func delete(for dayFolder: URL) {
        let url = dayFolder.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
