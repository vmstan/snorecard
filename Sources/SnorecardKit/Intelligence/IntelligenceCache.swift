import Foundation
import CryptoKit

/// Per-day sidecar that caches generated narratives keyed on a
/// canonical hash of their inputs. Lives next to
/// `.snorecard-stats.json` and `.snorecard-notes.json` inside each
/// day folder.
///
/// Reasoning for a distinct sidecar (rather than piggy-backing on
/// `DailyStatsCache`):
///
/// - Narratives depend on the user's free-form note, whose
///   lifecycle doesn't match the stats fingerprint.
/// - `Library.invalidateStatsCacheAndReload` is intentionally
///   narrow — it only removes `DailyStatsCache.filename` — and we
///   don't want rebuilding stats to discard every cached narrative.
/// - Narratives include a `promptTemplateVersion` that stats don't
///   have.
public enum IntelligenceCache {
    public static let dayFilename = ".snorecard-intelligence.json"
    public static let deviceFilename = ".snorecard-intelligence.json"

    // MARK: - Versioning

    /// Bump when the on-device model updates (Apple may add a
    /// hook for this; until then we pin to a constant so we can
    /// invalidate manually with a single-line change).
    public static let modelVersion = "foundation-1"

    // MARK: - Payloads

    public struct DayPayload: Codable, Sendable {
        public var nightSummary: Entry<NightSummaryOutput>?
        public var metricExplains: [String: Entry<MetricExplainOutput>]

        public init(
            nightSummary: Entry<NightSummaryOutput>? = nil,
            metricExplains: [String: Entry<MetricExplainOutput>] = [:]
        ) {
            self.nightSummary = nightSummary
            self.metricExplains = metricExplains
        }
    }

    public struct DevicePayload: Codable, Sendable {
        /// Keyed on `(rangeStart..rangeEnd..sampleSize)` hash so
        /// we can hold a rolling LRU of the last few ranges the
        /// user has looked at without writing a new file per
        /// range.
        public var overviewNarratives: [String: Entry<OverviewNarrativeOutput>]
        /// Keyed on a hash of the full `MetricExplainInput`, so
        /// the same metric + range + value combination hits the
        /// cache regardless of which Overview card opened it.
        public var overviewMetricExplains: [String: Entry<MetricExplainOutput>]

        public init(
            overviewNarratives: [String: Entry<OverviewNarrativeOutput>] = [:],
            overviewMetricExplains: [String: Entry<MetricExplainOutput>] = [:]
        ) {
            self.overviewNarratives = overviewNarratives
            self.overviewMetricExplains = overviewMetricExplains
        }

        private enum CodingKeys: String, CodingKey {
            case overviewNarratives, overviewMetricExplains
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.overviewNarratives = try container.decodeIfPresent(
                [String: Entry<OverviewNarrativeOutput>].self,
                forKey: .overviewNarratives
            ) ?? [:]
            self.overviewMetricExplains = try container.decodeIfPresent(
                [String: Entry<MetricExplainOutput>].self,
                forKey: .overviewMetricExplains
            ) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(overviewNarratives, forKey: .overviewNarratives)
            try container.encode(overviewMetricExplains, forKey: .overviewMetricExplains)
        }
    }

    public struct Entry<T: Codable & Sendable>: Codable, Sendable {
        public let inputHash: String
        public let modelVersion: String
        public let promptTemplateVersion: Int
        public let taxonomyVersion: Int
        public let output: T
        public let generatedAt: Date

        public init(
            inputHash: String,
            modelVersion: String,
            promptTemplateVersion: Int,
            taxonomyVersion: Int = NoteTagTaxonomy.version,
            output: T,
            generatedAt: Date = Date()
        ) {
            self.inputHash = inputHash
            self.modelVersion = modelVersion
            self.promptTemplateVersion = promptTemplateVersion
            self.taxonomyVersion = taxonomyVersion
            self.output = output
            self.generatedAt = generatedAt
        }
    }

    // MARK: - Hashing

    /// Canonical SHA-256 of an `Encodable` input. Used for every
    /// cache key so tiny float drift (after rounding in the prompt
    /// builders) produces the same hash.
    public static func hash(of value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Day sidecar I/O

    public static func loadDay(for dayFolder: URL) -> DayPayload {
        let url = dayFolder.appendingPathComponent(dayFilename)
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(DayPayload.self, from: data)
        else { return DayPayload() }
        return payload
    }

    public static func saveDay(_ payload: DayPayload, to dayFolder: URL) {
        let url = dayFolder.appendingPathComponent(dayFilename)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func loadNightSummary(
        for dayFolder: URL,
        matching inputHash: String,
        templateVersion: Int
    ) -> NightSummaryOutput? {
        let payload = loadDay(for: dayFolder)
        guard let entry = payload.nightSummary,
              entry.inputHash == inputHash,
              entry.modelVersion == modelVersion,
              entry.promptTemplateVersion == templateVersion
        else { return nil }
        return entry.output
    }

    public static func saveNightSummary(
        _ output: NightSummaryOutput,
        inputHash: String,
        templateVersion: Int,
        to dayFolder: URL
    ) {
        var payload = loadDay(for: dayFolder)
        payload.nightSummary = Entry(
            inputHash: inputHash,
            modelVersion: modelVersion,
            promptTemplateVersion: templateVersion,
            output: output
        )
        saveDay(payload, to: dayFolder)
    }

    public static func loadMetricExplain(
        for dayFolder: URL,
        metric: ExplainableMetric,
        matching inputHash: String,
        templateVersion: Int
    ) -> MetricExplainOutput? {
        let payload = loadDay(for: dayFolder)
        guard let entry = payload.metricExplains[metric.rawValue],
              entry.inputHash == inputHash,
              entry.modelVersion == modelVersion,
              entry.promptTemplateVersion == templateVersion
        else { return nil }
        return entry.output
    }

    public static func saveMetricExplain(
        _ output: MetricExplainOutput,
        metric: ExplainableMetric,
        inputHash: String,
        templateVersion: Int,
        to dayFolder: URL
    ) {
        var payload = loadDay(for: dayFolder)
        payload.metricExplains[metric.rawValue] = Entry(
            inputHash: inputHash,
            modelVersion: modelVersion,
            promptTemplateVersion: templateVersion,
            output: output
        )
        // LRU trim — keep the most-recently-generated 7 entries.
        if payload.metricExplains.count > 7 {
            let sorted = payload.metricExplains
                .sorted { $0.value.generatedAt > $1.value.generatedAt }
                .prefix(7)
            payload.metricExplains = Dictionary(
                uniqueKeysWithValues: sorted.map { ($0.key, $0.value) }
            )
        }
        saveDay(payload, to: dayFolder)
    }

    // MARK: - Device-level overview narrative sidecar

    public static func loadDevice(for deviceFolder: URL) -> DevicePayload {
        let url = deviceFolder.appendingPathComponent(deviceFilename)
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(DevicePayload.self, from: data)
        else { return DevicePayload() }
        return payload
    }

    public static func saveDevice(_ payload: DevicePayload, to deviceFolder: URL) {
        let url = deviceFolder.appendingPathComponent(deviceFilename)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func loadOverviewNarrative(
        for deviceFolder: URL,
        matching inputHash: String,
        templateVersion: Int
    ) -> OverviewNarrativeOutput? {
        let payload = loadDevice(for: deviceFolder)
        guard let entry = payload.overviewNarratives[inputHash],
              entry.modelVersion == modelVersion,
              entry.promptTemplateVersion == templateVersion
        else { return nil }
        return entry.output
    }

    public static func saveOverviewNarrative(
        _ output: OverviewNarrativeOutput,
        inputHash: String,
        templateVersion: Int,
        to deviceFolder: URL
    ) {
        var payload = loadDevice(for: deviceFolder)
        payload.overviewNarratives[inputHash] = Entry(
            inputHash: inputHash,
            modelVersion: modelVersion,
            promptTemplateVersion: templateVersion,
            output: output
        )
        // LRU trim — cap at 16 ranges so the sidecar stays small.
        if payload.overviewNarratives.count > 16 {
            let sorted = payload.overviewNarratives
                .sorted { $0.value.generatedAt > $1.value.generatedAt }
                .prefix(16)
            payload.overviewNarratives = Dictionary(
                uniqueKeysWithValues: sorted.map { ($0.key, $0.value) }
            )
        }
        saveDevice(payload, to: deviceFolder)
    }

    public static func loadOverviewMetricExplain(
        for deviceFolder: URL,
        matching inputHash: String,
        templateVersion: Int
    ) -> MetricExplainOutput? {
        let payload = loadDevice(for: deviceFolder)
        guard let entry = payload.overviewMetricExplains[inputHash],
              entry.modelVersion == modelVersion,
              entry.promptTemplateVersion == templateVersion
        else { return nil }
        return entry.output
    }

    public static func saveOverviewMetricExplain(
        _ output: MetricExplainOutput,
        inputHash: String,
        templateVersion: Int,
        to deviceFolder: URL
    ) {
        var payload = loadDevice(for: deviceFolder)
        payload.overviewMetricExplains[inputHash] = Entry(
            inputHash: inputHash,
            modelVersion: modelVersion,
            promptTemplateVersion: templateVersion,
            output: output
        )
        // LRU trim — Overview has up to a dozen cards and a few
        // range presets; 32 entries comfortably covers repeat
        // taps without unbounded growth.
        if payload.overviewMetricExplains.count > 32 {
            let sorted = payload.overviewMetricExplains
                .sorted { $0.value.generatedAt > $1.value.generatedAt }
                .prefix(32)
            payload.overviewMetricExplains = Dictionary(
                uniqueKeysWithValues: sorted.map { ($0.key, $0.value) }
            )
        }
        saveDevice(payload, to: deviceFolder)
    }

    // MARK: - Encoders

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
