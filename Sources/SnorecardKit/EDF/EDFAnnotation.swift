import Foundation

/// A single EDF+ Time-stamped Annotation List entry.
public struct EDFAnnotation: Sendable, Equatable {
    /// Offset in seconds from the file start time.
    public let onset: Double
    /// Duration in seconds, or nil when the annotation is instantaneous.
    public let duration: Double?
    /// Annotation text. An empty string denotes a record-start marker (ignored by callers).
    public let text: String
}

enum EDFAnnotationDecoder {
    /// Decode all TALs (Time-stamped Annotation Lists) from a concatenated annotation byte buffer.
    /// TAL grammar (simplified): `+<onset>[\x15<duration>]\x14<text>\x14...[\x14]\x00`.
    /// The first TAL in each record carries only the onset and an empty text — it marks record start.
    static func decode(_ bytes: Data) -> [EDFAnnotation] {
        var out: [EDFAnnotation] = []
        var index = bytes.startIndex
        let end = bytes.endIndex

        while index < end {
            // Skip padding zeros.
            while index < end, bytes[index] == 0 { index = bytes.index(after: index) }
            guard index < end else { break }

            // Find the next \x00 — end of this TAL.
            guard let talEnd = bytes[index..<end].firstIndex(of: 0) else { break }
            let talSlice = bytes[index..<talEnd]
            index = bytes.index(after: talEnd)

            parseTAL(talSlice, into: &out)
        }

        return out
    }

    private static func parseTAL(_ tal: Data, into out: inout [EDFAnnotation]) {
        // Split onset[\x15duration] from the annotations.
        guard let firstSeparator = tal.firstIndex(of: 0x14) else { return }
        let head = tal[tal.startIndex..<firstSeparator]
        var rest = tal[tal.index(after: firstSeparator)..<tal.endIndex]

        let (onset, duration) = parseOnset(head)
        guard let onset else { return }

        // Annotations are separated by \x14, terminated by a trailing \x14.
        while !rest.isEmpty {
            let nextSep = rest.firstIndex(of: 0x14) ?? rest.endIndex
            let annotationBytes = rest[rest.startIndex..<nextSep]
            let text = String(decoding: annotationBytes, as: UTF8.self)
            if !text.isEmpty {
                out.append(EDFAnnotation(onset: onset, duration: duration, text: text))
            }
            if nextSep == rest.endIndex { break }
            rest = rest[rest.index(after: nextSep)..<rest.endIndex]
        }
    }

    private static func parseOnset(_ head: Data) -> (onset: Double?, duration: Double?) {
        // head = "+123.456" or "+123.456\x1510.0"
        let parts = head.split(separator: 0x15, maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return (nil, nil) }
        let onsetStr = String(decoding: first, as: UTF8.self)
        let onset = Double(onsetStr)
        var duration: Double? = nil
        if parts.count == 2 {
            let durStr = String(decoding: parts[1], as: UTF8.self)
            duration = Double(durStr)
        }
        return (onset, duration)
    }
}

extension EDFFile {
    /// Decode every EDF+ annotation across all annotation signals in the file.
    /// Record-start markers (empty annotations) are filtered out.
    public func annotations() throws -> [EDFAnnotation] {
        var out: [EDFAnnotation] = []
        for (index, signal) in signals.enumerated() where signal.isAnnotation {
            let bytes = try annotationBytes(ofSignal: index)
            out.append(contentsOf: EDFAnnotationDecoder.decode(bytes))
        }
        return out
    }
}
