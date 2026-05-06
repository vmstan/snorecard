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
    /// Tags the user has explicitly asserted via the Sleep Journal
    /// tag picker. When non-nil this takes precedence over
    /// `extractedTags` for correlation and prompt context — the
    /// user's own labelling is authoritative. `nil` means "the user
    /// hasn't overridden"; `[]` means "the user has asserted that
    /// no tags apply", which also suppresses the AI extraction.
    public var userTags: [NoteTag]?
    /// Subjective 1–5 rating the user gave the night. `nil` means
    /// the user hasn't rated it yet. Kept as an `Int` rather than an
    /// enum so future re-scaling (1–10, 0–100) doesn't require a
    /// migration — the bounds are enforced at the UI layer.
    public var subjectiveScore: Int?
    /// Mask the user wore for each CPAP session on this day. Keys
    /// are session keys (the `YYYYMMDD_HHMMSS` filename prefix shared
    /// by a session's BRP / EVE / PLD trio); values are
    /// `Mask.id.uuidString` pointers into the user's iCloud-KVS
    /// catalog. `nil` means "no per-session masks recorded for this
    /// day yet" and is the steady state for legacy nights from
    /// before the mask feature shipped. Optional + Codable so old
    /// readers that don't know the field decode cleanly.
    public var sessionMasks: [String: String]?

    public init(
        text: String,
        updatedAt: Date = Date(),
        extractedTags: [NoteTag]? = nil,
        tagsInputHash: String? = nil,
        taxonomyVersion: Int? = nil,
        userTags: [NoteTag]? = nil,
        subjectiveScore: Int? = nil,
        sessionMasks: [String: String]? = nil
    ) {
        self.text = text
        self.updatedAt = updatedAt
        self.extractedTags = extractedTags
        self.tagsInputHash = tagsInputHash
        self.taxonomyVersion = taxonomyVersion
        self.userTags = userTags
        self.subjectiveScore = subjectiveScore
        self.sessionMasks = sessionMasks
    }

    /// Tags that downstream consumers (correlation, AI prompts)
    /// should treat as authoritative for this night. Prefers the
    /// user-asserted list so a user override always wins over the
    /// AI extraction — even when the user has explicitly said "no
    /// tags" by clearing the picker.
    public var effectiveTags: [NoteTag] {
        if let userTags { return userTags }
        return extractedTags ?? []
    }

    /// True when the sidecar has nothing worth persisting — no
    /// text, no user tags, no rating, no per-session mask
    /// assignments. The cache uses this to decide whether to delete
    /// the file on save, so a stamp-at-import write that only
    /// populated `sessionMasks` still persists rather than
    /// boomeranging through "save then delete."
    public var isEmpty: Bool {
        let blankText = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        let noTags = (userTags ?? []).isEmpty
        let noScore = subjectiveScore == nil
        let noMasks = (sessionMasks ?? [:]).isEmpty
        return blankText && noTags && noScore && noMasks
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

    /// Persist `note` for the day folder. Passing `nil`, or a note
    /// whose `text`, user tags and rating are all empty, deletes
    /// the sidecar so journals with no content don't clutter up
    /// iCloud. Writes are atomic so a crash mid-write never leaves
    /// a corrupt sidecar on disk.
    public static func save(_ note: DailyNote?, to dayFolder: URL) {
        let url = dayFolder.appendingPathComponent(filename)
        let fm = FileManager.default
        guard let note, !note.isEmpty else {
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
