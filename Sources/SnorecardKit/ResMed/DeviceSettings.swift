import Foundation

/// Snapshot of the therapy / comfort / humidifier / accessory
/// settings active on a single night, parsed from the `S.*` signals
/// in `STR.edf`. Every field is optional because:
///
/// - Different ResMed families expose different signals (AirSense 11
///   has no BiLevel / VAuto signals; AirCurve lacks the AutoSet for
///   Her pressures; etc.), and
/// - The `S.*` signals only carry values when `STR.edf` has a record
///   for that day — we want missing days to decode cleanly as `nil`.
public struct DeviceSettings: Codable, Sendable, Equatable {

    // MARK: - Therapy

    public var modeCode: Int?

    // CPAP (S.C.*)
    public var cpapPressure: Double?
    public var cpapStartPressure: Double?

    // AutoSet (S.A.*)
    public var autoMinPressure: Double?
    public var autoMaxPressure: Double?
    public var autoStartPressure: Double?

    // AutoSet for Her (S.AFH.*)
    public var autoForHerMinPressure: Double?
    public var autoForHerMaxPressure: Double?
    public var autoForHerStartPressure: Double?

    // BiLevel (S.BL.*)
    public var bilevelIPAP: Double?
    public var bilevelEPAP: Double?
    public var bilevelStartPressure: Double?

    // VAuto (S.VA.*)
    public var vautoMaxIPAP: Double?
    public var vautoMinEPAP: Double?
    public var vautoPressureSupport: Double?
    public var vautoStartPressure: Double?

    // MARK: - Comfort

    public var eprEnabled: Bool?
    public var eprLevel: Int?
    public var eprTypeCode: Int?

    public var rampEnableCode: Int?       // 0 off / 1 on / 2 auto
    public var rampTimeMinutes: Int?

    public var easyBreathe: Bool?
    public var smartStart: Bool?

    // MARK: - Humidifier

    public var climateControlCode: Int?   // 0 manual / 1 auto / (2 off seen on some firmware)
    public var humidityEnabled: Bool?
    public var humidityLevel: Int?        // 1–8 (0 = off)
    public var tubeTempEnableCode: Int?   // 0 off / 1 on / 2 auto
    public var tubeTempCelsius: Double?
    public var heatedTube: Bool?

    // MARK: - Accessories

    public var maskCode: Int?
    public var tubeCode: Int?

    public init() {}

    /// True when at least one field was successfully extracted — used
    /// by the UI to decide whether to show the empty state.
    public var hasAnyValue: Bool {
        modeCode != nil
            || cpapPressure != nil || autoMaxPressure != nil
            || bilevelIPAP != nil || vautoMaxIPAP != nil
            || eprEnabled != nil || rampEnableCode != nil
            || humidityLevel != nil || maskCode != nil
    }

    // MARK: - Decoded names (best-effort)

    public var modeName: String? {
        guard let modeCode else { return nil }
        switch modeCode {
        case 1: return "CPAP"
        case 2: return "APAP"
        case 3, 6: return "AutoSet"
        case 7: return "AutoSet for Her"
        case 8: return "VPAPauto"
        case 9: return "VPAP S"
        case 10: return "VPAP ST"
        case 11: return "iVAPS"
        case 12: return "ASV"
        case 13: return "ASVauto"
        default: return "Mode \(modeCode)"
        }
    }

    public var maskName: String? {
        guard let maskCode else { return nil }
        switch maskCode {
        case 0: return "Pillows"
        case 1: return "Full Face"
        case 2: return "Nasal"
        case 3: return "Nasal Pillows"
        default: return "Code \(maskCode)"
        }
    }

    public var tubeName: String? {
        guard let tubeCode else { return nil }
        switch tubeCode {
        case 0: return "Standard 22 mm"
        case 1: return "SlimLine 15 mm"
        case 2: return "ClimateLineAir"
        case 3: return "ClimateLineAir 15"
        case 4: return "ClimateLineAir Oxy"
        default: return "Code \(tubeCode)"
        }
    }

    public var climateControlName: String? {
        guard let climateControlCode else { return nil }
        switch climateControlCode {
        case 0: return "Manual"
        case 1: return "Auto"
        case 2: return "Off"
        default: return "Code \(climateControlCode)"
        }
    }

    public var eprTypeName: String? {
        guard let eprTypeCode else { return nil }
        switch eprTypeCode {
        case 0, 1: return "Ramp only"
        case 2: return "Full time"
        default: return "Code \(eprTypeCode)"
        }
    }

    public var rampModeName: String? {
        guard let rampEnableCode else { return nil }
        switch rampEnableCode {
        case 0: return "Off"
        case 1: return "On"
        case 2: return "Auto"
        default: return "Code \(rampEnableCode)"
        }
    }

    public var tubeTempEnableName: String? {
        guard let tubeTempEnableCode else { return nil }
        switch tubeTempEnableCode {
        case 0: return "Off"
        case 1: return "On"
        case 2: return "Auto"
        default: return "Code \(tubeTempEnableCode)"
        }
    }

    // MARK: - Decoding from STR.edf

    /// Decode a `DeviceSettings` from a single STR.edf record by
    /// asking the caller for scalar values keyed by signal label.
    /// Callers in `DailyStatistics.decode` already have the
    /// machinery to read one sample per signal per record — this
    /// just names the specific signals we care about. Returns `nil`
    /// when none of the signals yielded a value.
    public static func decode(
        scalar: (String) -> Double?
    ) -> DeviceSettings? {
        var s = DeviceSettings()

        // Therapy
        s.modeCode = scalar("Mode").map { Int($0) }
        s.cpapPressure = scalar("S.C.Press")
        s.cpapStartPressure = scalar("S.C.StartPress")
        s.autoMinPressure = scalar("S.A.MinPress")
        s.autoMaxPressure = scalar("S.A.MaxPress")
        s.autoStartPressure = scalar("S.A.StartPress")
        s.autoForHerMinPressure = scalar("S.AFH.MinPress")
        s.autoForHerMaxPressure = scalar("S.AFH.MaxPress")
        s.autoForHerStartPressure = scalar("S.AFH.StartPress")
        s.bilevelIPAP = scalar("S.BL.IPAP")
        s.bilevelEPAP = scalar("S.BL.EPAP")
        s.bilevelStartPressure = scalar("S.BL.StartPress")
        s.vautoMaxIPAP = scalar("S.VA.MaxIPAP")
        s.vautoMinEPAP = scalar("S.VA.MinEPAP")
        s.vautoPressureSupport = scalar("S.VA.PS")
        s.vautoStartPressure = scalar("S.VA.StartPress")

        // Comfort
        s.eprEnabled = scalar("S.EPR.EPREnable").map { $0 > 0 }
        s.eprLevel = scalar("S.EPR.Level").map { Int($0) }
        s.eprTypeCode = scalar("S.EPR.EPRType").map { Int($0) }
        s.rampEnableCode = scalar("S.RampEnable").map { Int($0) }
        s.rampTimeMinutes = scalar("S.RampTime").map { Int($0) }
        s.easyBreathe = scalar("S.EasyBreathe").map { $0 > 0 }
        s.smartStart = scalar("S.SmartStart").map { $0 > 0 }

        // Humidifier
        s.climateControlCode = scalar("S.ClimateControl").map { Int($0) }
        s.humidityEnabled = scalar("S.HumEnable").map { $0 > 0 }
        s.humidityLevel = scalar("S.HumLevel").map { Int($0) }
        s.tubeTempEnableCode = scalar("S.TempEnable").map { Int($0) }
        s.tubeTempCelsius = scalar("S.Temp")
        s.heatedTube = scalar("S.HeatedTube").map { $0 > 0 }

        // Accessories
        s.maskCode = scalar("S.Mask").map { Int($0) }
        s.tubeCode = scalar("S.Tube").map { Int($0) }

        return s.hasAnyValue ? s : nil
    }
}
