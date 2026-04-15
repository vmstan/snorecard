import Foundation

/// Metadata for a single signal within an EDF file.
public struct EDFSignal: Sendable, Equatable {
    public let label: String
    public let transducer: String
    public let physicalDimension: String
    public let physicalMin: Double
    public let physicalMax: Double
    public let digitalMin: Int
    public let digitalMax: Int
    public let prefiltering: String
    public let samplesPerRecord: Int

    /// True when this signal carries EDF+ annotations rather than numeric samples.
    public var isAnnotation: Bool { label == "EDF Annotations" }

    /// Gain to convert int16 digital values to physical units.
    public var gain: Double {
        let dRange = Double(digitalMax - digitalMin)
        guard dRange != 0 else { return 1 }
        return (physicalMax - physicalMin) / dRange
    }

    /// Offset applied after gain when converting int16 to physical units.
    public var offset: Double {
        physicalMin - Double(digitalMin) * gain
    }

    /// Convert a digital int16 sample to its physical value.
    public func physical(_ digital: Int16) -> Double {
        Double(digital) * gain + offset
    }
}

extension EDFSignal {
    /// Parse `ns` signal headers from the 256*ns bytes following the main header.
    static func parseAll(_ data: Data, signalCount ns: Int) throws -> [EDFSignal] {
        let needed = 256 * ns
        guard data.count >= needed else {
            throw EDFParseError.tooShort(expected: needed, got: data.count)
        }

        // Signal headers are grouped by field (all labels, then all transducers, …), not by signal.
        let base = data.startIndex
        func slice(_ fieldOffset: Int, _ perSignalLen: Int, _ index: Int) -> String {
            let start = base + fieldOffset + index * perSignalLen
            let end = start + perSignalLen
            return String(decoding: data[start..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }

        var offset = 0
        let labelOffset = offset; offset += 16 * ns
        let transducerOffset = offset; offset += 80 * ns
        let dimensionOffset = offset; offset += 8 * ns
        let pMinOffset = offset; offset += 8 * ns
        let pMaxOffset = offset; offset += 8 * ns
        let dMinOffset = offset; offset += 8 * ns
        let dMaxOffset = offset; offset += 8 * ns
        let prefilterOffset = offset; offset += 80 * ns
        let samplesOffset = offset; offset += 8 * ns
        // Remaining 32*ns reserved bytes intentionally ignored.

        return try (0..<ns).map { i in
            let label = slice(labelOffset, 16, i)
            let transducer = slice(transducerOffset, 80, i)
            let dimension = slice(dimensionOffset, 8, i)
            let pMinStr = slice(pMinOffset, 8, i)
            let pMaxStr = slice(pMaxOffset, 8, i)
            let dMinStr = slice(dMinOffset, 8, i)
            let dMaxStr = slice(dMaxOffset, 8, i)
            let prefilter = slice(prefilterOffset, 80, i)
            let samplesStr = slice(samplesOffset, 8, i)

            guard let pMin = Double(pMinStr) else {
                throw EDFParseError.badField(name: "physicalMin[\(i)]", raw: pMinStr)
            }
            guard let pMax = Double(pMaxStr) else {
                throw EDFParseError.badField(name: "physicalMax[\(i)]", raw: pMaxStr)
            }
            guard let dMin = Int(dMinStr) else {
                throw EDFParseError.badField(name: "digitalMin[\(i)]", raw: dMinStr)
            }
            guard let dMax = Int(dMaxStr) else {
                throw EDFParseError.badField(name: "digitalMax[\(i)]", raw: dMaxStr)
            }
            guard let samples = Int(samplesStr), samples >= 0 else {
                throw EDFParseError.badField(name: "samplesPerRecord[\(i)]", raw: samplesStr)
            }

            return EDFSignal(
                label: label,
                transducer: transducer,
                physicalDimension: dimension,
                physicalMin: pMin,
                physicalMax: pMax,
                digitalMin: dMin,
                digitalMax: dMax,
                prefiltering: prefilter,
                samplesPerRecord: samples
            )
        }
    }
}
