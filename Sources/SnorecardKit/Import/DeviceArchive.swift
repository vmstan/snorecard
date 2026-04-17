import Foundation
import AppleArchive
import System

/// Compress / decompress a device folder using Apple's native
/// Archive framework (LZFSE compression, `.aar` container).
///
/// Used by the Options menu's "Back Up Device" / "Restore" flow to
/// bundle everything inside a device folder — `Identification.*`,
/// `STR.edf`, every `DATALOG/YYYYMMDD/` sub-tree with its sidecars
/// and notes — into a single file that rides iCloud Drive
/// alongside the device data itself.
///
/// We intentionally choose Apple Archive over zip because:
///
/// - LZFSE is dramatically faster than Deflate on Apple silicon and
///   produces smaller archives on EDF data.
/// - No external dependency; `AppleArchive` framework ships with
///   macOS 11+ and iOS 14+.
/// - Preserves extended attributes and Unix permissions, which
///   matters for iCloud placeholder handling.
public enum DeviceArchive {

    public enum Error: Swift.Error, CustomStringConvertible {
        case cannotOpenWriteStream(URL)
        case cannotOpenReadStream(URL)
        case cannotCreateCompressor
        case cannotCreateDecompressor
        case cannotCreateEncoder
        case cannotCreateDecoder
        case cannotCreateExtractor(URL)
        case extractionFailed

        public var description: String {
            switch self {
            case .cannotOpenWriteStream(let url):
                return "Couldn't create archive at \(url.path)"
            case .cannotOpenReadStream(let url):
                return "Couldn't read archive at \(url.path)"
            case .cannotCreateCompressor:
                return "Couldn't initialise LZFSE compressor"
            case .cannotCreateDecompressor:
                return "Couldn't initialise LZFSE decompressor"
            case .cannotCreateEncoder:
                return "Couldn't initialise archive encoder"
            case .cannotCreateDecoder:
                return "Couldn't initialise archive decoder"
            case .cannotCreateExtractor(let url):
                return "Couldn't create extractor at \(url.path)"
            case .extractionFailed:
                return "Archive extraction failed"
            }
        }
    }

    /// Compress every file under `sourceDirectory` into a single
    /// `.aar` archive at `destination`. Called from a detached task
    /// in `Library` so the main actor never blocks on this.
    public static func compress(
        directory sourceDirectory: URL,
        to destination: URL
    ) throws {
        let sourcePath = FilePath(sourceDirectory.path)
        let destinationPath = FilePath(destination.path)

        guard let writeStream = ArchiveByteStream.fileStream(
            path: destinationPath,
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644)
        ) else {
            throw Error.cannotOpenWriteStream(destination)
        }
        defer { try? writeStream.close() }

        guard let compressStream = ArchiveByteStream.compressionStream(
            using: .lzfse,
            writingTo: writeStream
        ) else {
            throw Error.cannotCreateCompressor
        }
        defer { try? compressStream.close() }

        guard let encodeStream = ArchiveStream.encodeStream(
            writingTo: compressStream
        ) else {
            throw Error.cannotCreateEncoder
        }
        defer { try? encodeStream.close() }

        // Capture the full set of per-entry metadata fields so a
        // round-trip archive → extract restores file mode,
        // timestamps, and any extended attributes sidecars may
        // have accumulated during their life in iCloud.
        guard let keySet = ArchiveHeader.FieldKeySet(
            "TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM"
        ) else {
            throw Error.cannotCreateEncoder
        }

        try encodeStream.writeDirectoryContents(
            archiveFrom: sourcePath,
            keySet: keySet
        )
    }

    /// Expand a `.aar` archive into `destinationDirectory`. The
    /// destination is created if it doesn't exist; extracted paths
    /// are relative to it, matching the layout the source folder
    /// had when it was compressed.
    public static func decompress(
        archive sourceArchive: URL,
        into destinationDirectory: URL
    ) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationDirectory.path) {
            try fm.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
        }

        let sourcePath = FilePath(sourceArchive.path)
        let destPath = FilePath(destinationDirectory.path)

        guard let readStream = ArchiveByteStream.fileStream(
            path: sourcePath,
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644)
        ) else {
            throw Error.cannotOpenReadStream(sourceArchive)
        }
        defer { try? readStream.close() }

        guard let decompressStream = ArchiveByteStream.decompressionStream(
            readingFrom: readStream
        ) else {
            throw Error.cannotCreateDecompressor
        }
        defer { try? decompressStream.close() }

        guard let decodeStream = ArchiveStream.decodeStream(
            readingFrom: decompressStream
        ) else {
            throw Error.cannotCreateDecoder
        }
        defer { try? decodeStream.close() }

        guard let extractStream = ArchiveStream.extractStream(
            extractingTo: destPath,
            flags: [.ignoreOperationNotPermitted]
        ) else {
            throw Error.cannotCreateExtractor(destinationDirectory)
        }
        defer { try? extractStream.close() }

        _ = try ArchiveStream.process(
            readingFrom: decodeStream,
            writingTo: extractStream
        )
    }
}
