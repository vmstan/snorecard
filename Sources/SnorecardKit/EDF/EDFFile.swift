import Foundation

/// A parsed EDF/EDF+ file with lazy access to signal sample data.
///
/// The entire file is loaded into memory on `init`. For ResMed SD card files
/// that's fine — even a full night of 25Hz waveform is only a few megabytes.
public struct EDFFile: Sendable {
    public let url: URL
    public let header: EDFHeader
    public let signals: [EDFSignal]
    private let data: Data

    /// Byte length of a single data record across all signals.
    public var recordByteLength: Int {
        signals.reduce(0) { $0 + $1.samplesPerRecord * 2 }
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data, url: url)
    }

    public init(data: Data, url: URL = URL(fileURLWithPath: "/dev/null")) throws {
        self.url = url
        self.data = data
        var header = try EDFHeader.parseMain(data)

        let signalHeaderStart = data.startIndex + 256
        let signalHeaderLen = 256 * header.signalCount
        guard data.count >= 256 + signalHeaderLen else {
            throw EDFParseError.tooShort(
                expected: 256 + signalHeaderLen,
                got: data.count
            )
        }
        let signalHeaderSlice = data[signalHeaderStart..<(signalHeaderStart + signalHeaderLen)]
        let signals = try EDFSignal.parseAll(signalHeaderSlice, signalCount: header.signalCount)

        // ResMed devices occasionally write a file with an "unknown" record count
        // (the EDF sentinel of -1) if the session wasn't finalised cleanly. We
        // recover by dividing the data-section length by the per-record byte length.
        if header.recordCount < 0 {
            let recordLen = signals.reduce(0) { $0 + $1.samplesPerRecord * 2 }
            let dataBytes = data.count - (256 + signalHeaderLen)
            header.recordCount = recordLen > 0 ? max(0, dataBytes / recordLen) : 0
        }

        self.header = header
        self.signals = signals
    }

    /// Decode the raw int16 samples for `signalIndex` across every data record, concatenated.
    /// EDF samples are little-endian signed 16-bit integers.
    public func rawSamples(ofSignal signalIndex: Int) throws -> [Int16] {
        let signal = signals[signalIndex]
        let recordLen = recordByteLength
        let samplesPerRecord = signal.samplesPerRecord
        guard samplesPerRecord > 0 else { return [] }

        var signalByteOffsetInRecord = 0
        for i in 0..<signalIndex {
            signalByteOffsetInRecord += signals[i].samplesPerRecord * 2
        }

        let dataStart = data.startIndex + header.totalHeaderBytes
        let expectedBytes = header.recordCount * recordLen
        guard data.count - header.totalHeaderBytes >= expectedBytes else {
            throw EDFParseError.tooShort(
                expected: header.totalHeaderBytes + expectedBytes,
                got: data.count
            )
        }

        var out = [Int16]()
        out.reserveCapacity(header.recordCount * samplesPerRecord)

        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: dataStart - data.startIndex)
            for r in 0..<header.recordCount {
                let recordPtr = base.advanced(by: r * recordLen + signalByteOffsetInRecord)
                for s in 0..<samplesPerRecord {
                    let bytePtr = recordPtr.advanced(by: s * 2)
                    let lo = UInt16(bytePtr.load(fromByteOffset: 0, as: UInt8.self))
                    let hi = UInt16(bytePtr.load(fromByteOffset: 1, as: UInt8.self))
                    out.append(Int16(bitPattern: lo | (hi << 8)))
                }
            }
        }
        return out
    }

    /// Decode all samples for `signalIndex` converted to physical units.
    public func physicalSamples(ofSignal signalIndex: Int) throws -> [Double] {
        let signal = signals[signalIndex]
        let raw = try rawSamples(ofSignal: signalIndex)
        let gain = signal.gain
        let offset = signal.offset
        return raw.map { Double($0) * gain + offset }
    }

    /// Raw byte slice for the annotation signal at `signalIndex` across all records.
    /// Caller decodes TALs from this buffer.
    func annotationBytes(ofSignal signalIndex: Int) throws -> Data {
        let signal = signals[signalIndex]
        precondition(signal.isAnnotation, "signal \(signalIndex) is not an annotation signal")

        let recordLen = recordByteLength
        var signalByteOffsetInRecord = 0
        for i in 0..<signalIndex {
            signalByteOffsetInRecord += signals[i].samplesPerRecord * 2
        }
        let signalByteLength = signal.samplesPerRecord * 2
        let dataStart = data.startIndex + header.totalHeaderBytes

        var out = Data(capacity: header.recordCount * signalByteLength)
        for r in 0..<header.recordCount {
            let start = dataStart + r * recordLen + signalByteOffsetInRecord
            let end = start + signalByteLength
            guard end <= data.endIndex else {
                throw EDFParseError.tooShort(expected: end - data.startIndex, got: data.count)
            }
            out.append(data[start..<end])
        }
        return out
    }
}
