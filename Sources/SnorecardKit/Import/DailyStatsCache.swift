import Foundation

/// Persistent per-day cache of computed `DailyStatistics`.
///
/// Snorecard writes one sidecar file — `.snorecard-stats.json` — inside
/// every `DATALOG/YYYYMMDD/` folder. The cache is keyed by a fingerprint
/// of the EDF files in the folder so that edits or re-syncs invalidate
/// stale stats automatically. First import of a multi-month card still
/// takes the full time; subsequent re-loads skip the expensive decode.
public enum DailyStatsCache {

    /// Filename used for the sidecar inside every day folder.
    public static let filename = ".snorecard-stats.json"

    /// Fingerprint summary for a day's EDF files. Encoded into the
    /// sidecar so we can compare on read and invalidate when the data
    /// underneath has changed. ResMed writes each EDF exactly once,
    /// so the `(name, size)` tuple is stable across iCloud syncs —
    /// we intentionally don't include modification dates because
    /// those drift by seconds between devices and would cause
    /// spurious cache misses on iOS after a Mac import.
    ///
    /// `schemaVersion` is bumped whenever the aggregate's output
    /// semantics change (e.g. the < 2 min auto-exclude rule, the
    /// switch to using the kept-session count for `maskEvents`).
    /// Old caches decode with a default `schemaVersion = 1` and
    /// fail the equality check against the build's current value,
    /// triggering a fresh aggregate that overwrites the sidecar.
    public struct Fingerprint: Codable, Equatable, Sendable {
        public let files: [FileEntry]
        public let schemaVersion: Int

        public struct FileEntry: Codable, Equatable, Sendable {
            public let name: String
            public let size: Int
        }

        /// Bump this whenever the aggregate's per-day output changes
        /// in a way that should invalidate previously-saved caches.
        public static let currentSchemaVersion: Int = 7

        public init(files: [FileEntry], schemaVersion: Int = Fingerprint.currentSchemaVersion) {
            self.files = files
            self.schemaVersion = schemaVersion
        }

        private enum CodingKeys: String, CodingKey {
            case files
            case schemaVersion
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.files = try container.decode([FileEntry].self, forKey: .files)
            // Sidecars written before the schemaVersion field
            // existed implicitly belong to schema 1.
            self.schemaVersion = try container.decodeIfPresent(
                Int.self,
                forKey: .schemaVersion
            ) ?? 1
        }

        /// Build a fingerprint from the day's `ResMedDataFile` list by
        /// stat'ing each file.
        public static func build(for files: [ResMedDataFile]) -> Fingerprint {
            let fm = FileManager.default
            let entries = files
                .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
                .map { file -> FileEntry in
                    let attrs = try? fm.attributesOfItem(atPath: file.url.path)
                    let size = (attrs?[.size] as? Int) ?? file.byteSize ?? 0
                    return FileEntry(
                        name: file.url.lastPathComponent,
                        size: size
                    )
                }
            return Fingerprint(files: entries)
        }
    }

    /// Cache payload written to disk.
    private struct Payload: Codable {
        let fingerprint: Fingerprint
        let stats: DailyStatistics
    }

    /// Return the cached `DailyStatistics` for the given day folder when
    /// the sidecar exists AND its fingerprint matches the supplied
    /// file list. Returns `nil` on any mismatch or I/O error.
    public static func load(
        for dayFolder: URL,
        fingerprint: Fingerprint
    ) -> DailyStatistics? {
        let url = dayFolder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data),
              payload.fingerprint == fingerprint
        else { return nil }
        return payload.stats
    }

    /// Read whatever sidecar is on disk for `dayFolder`, regardless
    /// of whether its fingerprint matches today's files. Returns the
    /// previously-decoded stats so a new aggregate pass can merge
    /// forward the bits the fresh STR.edf no longer surfaces (most
    /// notably the `settings` block).
    public static func loadAnyStats(
        for dayFolder: URL
    ) -> DailyStatistics? {
        let url = dayFolder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data)
        else { return nil }
        return payload.stats
    }

    /// Write the sidecar atomically so partial writes never pollute the
    /// day folder. Silent on failure — the cache is best-effort.
    public static func save(
        _ stats: DailyStatistics,
        to dayFolder: URL,
        fingerprint: Fingerprint
    ) {
        let url = dayFolder.appendingPathComponent(filename)
        let payload = Payload(fingerprint: fingerprint, stats: stats)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
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
