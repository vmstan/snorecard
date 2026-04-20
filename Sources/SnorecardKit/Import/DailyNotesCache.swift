import Foundation

/// User-authored note attached to a single night. Stored as a small
/// JSON sidecar — `.snorecard-notes.json` — next to
/// `.snorecard-stats.json` inside the same `DATALOG/YYYYMMDD/`
/// folder. Rides iCloud Drive like the rest of the tree, so a note
/// follows its night across devices.
public struct DailyNote: Codable, Sendable, Equatable {
    /// Free-form text exactly as the user typed it — no trimming, no
    /// normalisation. Whitespace-only content is treated as "no note"
    /// by the persistence layer so empty edits clean up the sidecar.
    public var text: String
    /// Wall-clock timestamp of the most recent save. Not used for
    /// conflict resolution today (iCloud Drive's last-writer-wins is
    /// enough for a single-user flow) but recorded so we can
    /// surface it in the UI later ("edited 3 days ago").
    public var updatedAt: Date
    /// Tags extracted from `text` by the on-device note tag
    /// extractor. `nil` when extraction hasn't run yet;
    /// `[]` is a legitimate result and distinct from `nil`.
    public var extractedTags: [NoteTag]?
    /// SHA-256 of `text` at the moment `extractedTags` was
    /// generated. Lets the reader invalidate tags when the note
    /// has been edited since.
    public var tagsInputHash: String?
    /// `NoteTagTaxonomy.version` at the moment `extractedTags`
    /// was generated. Bumping the taxonomy version triggers bulk
    /// re-extraction on next read.
    public var taxonomyVersion: Int?

    public init(
        text: String,
        updatedAt: Date = Date(),
        extractedTags: [NoteTag]? = nil,
        tagsInputHash: String? = nil,
        taxonomyVersion: Int? = nil
    ) {
        self.text = text
        self.updatedAt = updatedAt
        self.extractedTags = extractedTags
        self.tagsInputHash = tagsInputHash
        self.taxonomyVersion = taxonomyVersion
    }
}

/// Read/write helper for the `.snorecard-notes.json` sidecar.
/// Intentionally distinct from `DailyStatsCache` so bulk-invalidate
/// flows (Rebuild Statistics) can target one without touching the
/// other — see `Library.invalidateStatsCacheAndReload` which only
/// removes files matching `DailyStatsCache.filename`.
public enum DailyNotesCache {

    /// Filename used for the sidecar inside every day folder.
    public static let filename = ".snorecard-notes.json"

    /// Load the note for a given day folder, or `nil` if none exists
    /// (or the existing file can't be decoded). Decode failures are
    /// silent — the note is a best-effort artefact, not a source of
    /// truth for anything else.
    public static func load(for dayFolder: URL) -> DailyNote? {
        let url = dayFolder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let note = try? decoder.decode(DailyNote.self, from: data)
        else { return nil }
        return note
    }

    /// Persist `note` for the day folder. Passing `nil` or a note
    /// whose `text` is whitespace-only deletes the sidecar so empty
    /// notes don't clutter up iCloud. Writes are atomic so a crash
    /// mid-write never leaves a corrupt sidecar on disk.
    public static func save(_ note: DailyNote?, to dayFolder: URL) {
        let url = dayFolder.appendingPathComponent(filename)
        let fm = FileManager.default
        let isBlank = note?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true
        if isBlank {
            try? fm.removeItem(at: url)
            return
        }
        guard let data = try? encoder.encode(note) else { return }
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
