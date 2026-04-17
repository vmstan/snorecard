import Foundation

/// Role of a ResMed EDF file within an SD card export, derived from its filename suffix.
public enum ResMedFileKind: String, Sendable, CaseIterable, Codable {
    /// Daily summary statistics (root of SD card).
    case summary = "STR"
    /// Breath Records: high-rate flow and mask-pressure waveforms.
    case breath = "BRP"
    /// Physiological Low-rate Data: leak, minute ventilation, tidal volume, pressure.
    case physiological = "PLD"
    /// Event annotations: apnea, hypopnea, periodic breathing markers.
    case events = "EVE"
    /// Oximetry: SpO2 and pulse (when an oximeter is attached).
    case oximetry = "SAD"
    /// Cheyne-Stokes respiration flags.
    case cheyneStokes = "CSL"

    public var humanName: String {
        switch self {
        case .summary: "Summary"
        case .breath: "Breath Waveform"
        case .physiological: "Physiological"
        case .events: "Events"
        case .oximetry: "Oximetry"
        case .cheyneStokes: "Cheyne-Stokes"
        }
    }
}

extension ResMedFileKind {
    /// Infer the file kind from a ResMed SD card filename.
    /// Expected forms: `STR.edf`, `YYYYMMDD_HHMMSS_XXX.edf` where XXX is the kind code.
    public static func from(filename: String) -> ResMedFileKind? {
        let stem = (filename as NSString).deletingPathExtension
        if stem == "STR" { return .summary }
        guard let lastUnderscore = stem.lastIndex(of: "_") else { return nil }
        let suffix = String(stem[stem.index(after: lastUnderscore)...])
        return ResMedFileKind(rawValue: suffix)
    }
}
