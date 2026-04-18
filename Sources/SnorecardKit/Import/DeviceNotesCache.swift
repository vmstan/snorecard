import Foundation

/// User-authored note attached to a device rather than a specific
/// night — the "overall" sleep journal for that CPAP. Stored as a
/// small JSON sidecar — `.snorecard-device-notes.json` — at the
/// root of the device folder (next to `DATALOG/`). Rides iCloud
/// Drive like the rest of the tree so the entry follows the
/// device across the user's Macs and iPhones.
public struct DeviceNote: Codable, Sendable, Equatable {
    /// Free-form text exactly as the user typed it — no trimming, no
    /// normalisation. Whitespace-only content is treated as "no note"
    /// by the persistence layer so empty edits clean up the sidecar.
    public var text: String
    /// Wall-clock timestamp of the most recent save. Recorded for the
    /// same "edited X days ago" surfacing `DailyNote` anticipates.
    public var updatedAt: Date

    public init(text: String, updatedAt: Date = Date()) {
        self.text = text
        self.updatedAt = updatedAt
    }
}

/// Read/write helper for the `.snorecard-device-notes.json` sidecar.
/// Mirrors `DailyNotesCache` so both journals share the same empty-
/// file cleanup behaviour and atomic-write guarantees.
public enum DeviceNotesCache {

    /// Filename used for the sidecar at the device folder's root.
    public static let filename = ".snorecard-device-notes.json"

    /// Load the note for a given device folder, or `nil` if none
    /// exists (or the existing file can't be decoded). Decode
    /// failures are silent — the note is a best-effort artefact.
    public static func load(for deviceFolder: URL) -> DeviceNote? {
        let url = deviceFolder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let note = try? decoder.decode(DeviceNote.self, from: data)
        else { return nil }
        return note
    }

    /// Persist `note` for the device folder. Passing `nil` or a note
    /// whose `text` is whitespace-only deletes the sidecar so empty
    /// notes don't clutter up iCloud. Writes are atomic so a crash
    /// mid-write never leaves a corrupt sidecar on disk.
    public static func save(_ note: DeviceNote?, to deviceFolder: URL) {
        let url = deviceFolder.appendingPathComponent(filename)
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
