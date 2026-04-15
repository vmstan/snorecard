import Foundation

/// Top-level metadata for an EDF/EDF+ file, parsed from the fixed 256-byte main header.
public struct EDFHeader: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case edf
        case edfPlusContinuous
        case edfPlusDiscontinuous
    }

    public let kind: Kind
    public let patientID: String
    public let recordingID: String
    public let startDate: Date
    public let headerBytes: Int
    /// EDF files written incrementally can carry `-1` here until the device finalises
    /// the file; `EDFFile` repairs the count from the data-section length on load.
    public internal(set) var recordCount: Int
    public let recordDuration: Double
    public let signalCount: Int

    /// Total header size including signal headers (main 256 bytes + 256 * signalCount).
    public var totalHeaderBytes: Int { 256 + 256 * signalCount }
}

enum EDFParseError: Error, CustomStringConvertible {
    case tooShort(expected: Int, got: Int)
    case badField(name: String, raw: String)
    case unsupportedVersion(String)

    var description: String {
        switch self {
        case .tooShort(let expected, let got):
            return "EDF file too short: need \(expected) bytes, have \(got)"
        case .badField(let name, let raw):
            return "EDF header field '\(name)' malformed: \(raw.debugDescription)"
        case .unsupportedVersion(let v):
            return "Unsupported EDF version: \(v.debugDescription)"
        }
    }
}

extension EDFHeader {
    /// Parse the 256-byte main header from `data`. Does not touch signal headers.
    static func parseMain(_ data: Data) throws -> EDFHeader {
        guard data.count >= 256 else {
            throw EDFParseError.tooShort(expected: 256, got: data.count)
        }

        func field(_ range: Range<Int>) -> String {
            let start = data.startIndex + range.lowerBound
            let end = data.startIndex + range.upperBound
            return String(decoding: data[start..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }

        let version = field(0..<8)
        guard version == "0" else {
            throw EDFParseError.unsupportedVersion(version)
        }

        let patient = field(8..<88)
        let recording = field(88..<168)
        let dateStr = field(168..<176)
        let timeStr = field(176..<184)
        let headerBytesStr = field(184..<192)
        let reserved = field(192..<236)
        let recordCountStr = field(236..<244)
        let durationStr = field(244..<252)
        let signalCountStr = field(252..<256)

        guard let headerBytes = Int(headerBytesStr) else {
            throw EDFParseError.badField(name: "header bytes", raw: headerBytesStr)
        }
        guard let recordCount = Int(recordCountStr) else {
            throw EDFParseError.badField(name: "record count", raw: recordCountStr)
        }
        guard let duration = Double(durationStr) else {
            throw EDFParseError.badField(name: "record duration", raw: durationStr)
        }
        guard let signalCount = Int(signalCountStr), signalCount >= 0 else {
            throw EDFParseError.badField(name: "signal count", raw: signalCountStr)
        }

        let kind: Kind
        switch reserved {
        case let r where r.hasPrefix("EDF+C"): kind = .edfPlusContinuous
        case let r where r.hasPrefix("EDF+D"): kind = .edfPlusDiscontinuous
        default: kind = .edf
        }

        let startDate = try parseStartDate(
            dateStr: dateStr,
            timeStr: timeStr,
            recordingID: recording
        )

        return EDFHeader(
            kind: kind,
            patientID: patient,
            recordingID: recording,
            startDate: startDate,
            headerBytes: headerBytes,
            recordCount: recordCount,
            recordDuration: duration,
            signalCount: signalCount
        )
    }

    /// EDF dates are `dd.mm.yy`; the spec resolves 00-84 → 2000-2084 and 85-99 → 1985-1999.
    /// EDF+ files also carry an absolute `Startdate dd-MMM-yyyy` token in the recording ID — prefer that when present.
    private static func parseStartDate(
        dateStr: String,
        timeStr: String,
        recordingID: String
    ) throws -> Date {
        // EDF headers store wall-clock time with no timezone — interpret in the
        // current local calendar so display matches what the device showed.
        let calendar = Calendar.current

        var components = DateComponents()
        let timeParts = timeStr.split(separator: ".").compactMap { Int($0) }
        guard timeParts.count == 3 else {
            throw EDFParseError.badField(name: "start time", raw: timeStr)
        }
        components.hour = timeParts[0]
        components.minute = timeParts[1]
        components.second = timeParts[2]

        if let absYear = absoluteYear(fromRecordingID: recordingID),
           let dayMonth = try? parseDayMonth(dateStr) {
            components.year = absYear
            components.month = dayMonth.month
            components.day = dayMonth.day
        } else {
            let parts = dateStr.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 3 else {
                throw EDFParseError.badField(name: "start date", raw: dateStr)
            }
            components.day = parts[0]
            components.month = parts[1]
            let yy = parts[2]
            components.year = yy >= 85 ? 1900 + yy : 2000 + yy
        }

        guard let date = calendar.date(from: components) else {
            throw EDFParseError.badField(name: "start date", raw: "\(dateStr) \(timeStr)")
        }
        return date
    }

    private static func absoluteYear(fromRecordingID id: String) -> Int? {
        // EDF+ recording ID format: "Startdate dd-MMM-yyyy ..."
        guard let range = id.range(of: "Startdate ") else { return nil }
        let tail = id[range.upperBound...]
        let token = tail.split(separator: " ").first.map(String.init) ?? ""
        let pieces = token.split(separator: "-")
        guard pieces.count == 3, let year = Int(pieces[2]) else { return nil }
        return year
    }

    private static func parseDayMonth(_ dateStr: String) throws -> (day: Int, month: Int) {
        let parts = dateStr.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else {
            throw EDFParseError.badField(name: "start date", raw: dateStr)
        }
        return (parts[0], parts[1])
    }
}
