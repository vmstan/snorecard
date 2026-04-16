import Foundation

/// Device identification parsed from `Identification.tgt` at the SD card root.
///
/// The file is a newline-separated list of `#TAG value` lines. We extract the
/// fields OSCAR-lite needs and keep the full map for future use.
public struct ResMedIdentification: Sendable, Equatable {
    public let serialNumber: String?
    public let productName: String?
    public let productCode: String?
    public let modelID: String?
    public let firmware: String?
    public let rawFields: [String: String]

    public init(
        serialNumber: String?,
        productName: String?,
        productCode: String?,
        modelID: String?,
        firmware: String?,
        rawFields: [String: String]
    ) {
        self.serialNumber = serialNumber
        self.productName = productName
        self.productCode = productCode
        self.modelID = modelID
        self.firmware = firmware
        self.rawFields = rawFields
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json" {
            self = try Self.parseJSON(data)
        } else {
            let text = String(decoding: data, as: UTF8.self)
            self = Self.parse(text)
        }
    }

    /// Locate a supported identification file at the SD root. AirSense
    /// 10-family machines write `Identification.tgt`; AirSense 11 uses
    /// `Identification.json` with a different schema.
    public static func locate(in root: URL) -> URL? {
        let fm = FileManager.default
        let tgt = root.appendingPathComponent("Identification.tgt")
        if fm.fileExists(atPath: tgt.path) { return tgt }
        let json = root.appendingPathComponent("Identification.json")
        if fm.fileExists(atPath: json.path) { return json }
        return nil
    }

    /// Decode the `Identification.json` format used by the AirSense 11.
    /// The schema nests product metadata under
    /// `FlowGenerator.IdentificationProfiles.Product` / `Software`.
    public static func parseJSON(_ data: Data) throws -> ResMedIdentification {
        struct Root: Decodable {
            let FlowGenerator: FlowGenerator
        }
        struct FlowGenerator: Decodable {
            let IdentificationProfiles: Profiles
        }
        struct Profiles: Decodable {
            let Product: Product
            let Software: Software?
        }
        struct Product: Decodable {
            let SerialNumber: String?
            let ProductName: String?
            let ProductCode: String?
        }
        struct Software: Decodable {
            let ApplicationIdentifier: String?
        }

        let decoded = try JSONDecoder().decode(Root.self, from: data)
        let product = decoded.FlowGenerator.IdentificationProfiles.Product
        let firmware = decoded.FlowGenerator.IdentificationProfiles.Software?.ApplicationIdentifier

        var raw: [String: String] = [:]
        if let s = product.SerialNumber { raw["SerialNumber"] = s }
        if let n = product.ProductName { raw["ProductName"] = n }
        if let c = product.ProductCode { raw["ProductCode"] = c }
        if let f = firmware { raw["ApplicationIdentifier"] = f }

        return ResMedIdentification(
            serialNumber: product.SerialNumber,
            productName: product.ProductName,
            productCode: product.ProductCode,
            modelID: nil,
            firmware: firmware,
            rawFields: raw
        )
    }

    public static func parse(_ text: String) -> ResMedIdentification {
        var fields: [String: String] = [:]
        // Swift treats \r\n as a single grapheme cluster, so character-level
        // splitting misses CRLF boundaries. components(separatedBy: .newlines)
        // handles CR/LF/CRLF uniformly.
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let dropped = trimmed.dropFirst()
            guard let space = dropped.firstIndex(of: " ") else { continue }
            let tag = String(dropped[..<space])
            let value = dropped[dropped.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            fields[tag] = value
        }
        return ResMedIdentification(
            serialNumber: fields["SRN"],
            productName: fields["PNA"]?.replacingOccurrences(of: "_", with: " "),
            productCode: fields["PCD"],
            modelID: fields["MID"],
            firmware: fields["FGT"],
            rawFields: fields
        )
    }
}
