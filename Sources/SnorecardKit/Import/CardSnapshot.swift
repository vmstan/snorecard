import Foundation

/// Persists the last-loaded `ResMedSDCard` to disk so the sidebar
/// can render a populated day list on the next launch before any
/// I/O completes. Snapshots are keyed on device serial so switching
/// devices doesn't clobber a sibling machine's snapshot.
public enum CardSnapshot {

    /// Bumped whenever the on-disk payload shape changes in a way
    /// that older builds can't decode. A mismatch is treated as a
    /// cache miss — `Library` just falls through to the normal
    /// `load()` path.
    private static let schemaVersion = 1

    private struct Payload: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let card: ResMedSDCard
    }

    /// Write a snapshot for the given card. Silent on failure — the
    /// snapshot is a performance aid, not a source of truth.
    public static func save(_ card: ResMedSDCard) {
        guard let url = snapshotURL(for: card) else { return }
        do {
            try ensureDirectoryExists(url.deletingLastPathComponent())
            let payload = Payload(
                schemaVersion: schemaVersion,
                savedAt: Date(),
                card: card
            )
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort — log-free so we don't spam on sandboxed iOS.
        }
    }

    /// Load the most recent snapshot for `serial`, returning `nil`
    /// when absent, unreadable, or written by an incompatible schema.
    public static func load(forSerial serial: String) -> ResMedSDCard? {
        guard let url = snapshotURL(forSerial: serial),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data),
              payload.schemaVersion == schemaVersion
        else { return nil }
        return payload.card
    }

    /// Delete every snapshot we've ever written — useful if the user
    /// manually blows away data and we don't want stale days
    /// reappearing. Silent on failure.
    public static func clearAll() {
        guard let dir = snapshotsDirectory() else { return }
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in contents where item.pathExtension == "json" {
                try? fm.removeItem(at: item)
            }
        }
    }

    // MARK: - Paths

    private static func snapshotURL(for card: ResMedSDCard) -> URL? {
        guard let serial = card.identification?.serialNumber, !serial.isEmpty else {
            return nil
        }
        return snapshotURL(forSerial: serial)
    }

    /// Resolves to `nil` — rather than a rooted path — when `serial`
    /// can't be sanitized into a safe filename component. Previously
    /// this only replaced `/`, which let `..` segments escape the
    /// snapshots directory. Callers treat `nil` as "no snapshot to
    /// read or write," which is the safe default.
    private static func snapshotURL(forSerial serial: String) -> URL? {
        guard let sanitized = ResMedIdentification.sanitizedSerial(serial) else {
            return nil
        }
        let base = snapshotsDirectory() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("last-card-\(sanitized).json")
    }

    private static func snapshotsDirectory() -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport
            .appendingPathComponent("Snorecard", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    private static func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Codec

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
