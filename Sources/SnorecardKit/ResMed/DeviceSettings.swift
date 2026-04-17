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

    /// `S.RiseEnable` — whether the clinician enabled a manual
    /// Rise Time override for bilevel/VAuto modes.
    public var riseTimeEnabled: Bool?
    /// `S.RiseTime` — ms it takes to transition from EPAP to IPAP.
    public var riseTimeMs: Int?

    // MARK: - Bilevel / VAuto timing

    /// `S.Trigger` — inspiration-trigger sensitivity on a 0–4
    /// (Very Low / Low / Medium / High / Very High) scale.
    public var triggerSensitivityCode: Int?
    /// `S.Cycle` — expiration-cycle sensitivity, same 0–4 scale.
    public var cycleSensitivityCode: Int?
    /// `S.TiMax` — maximum inspiratory time in seconds.
    public var tiMaxSeconds: Double?
    /// `S.TiMin` — minimum inspiratory time in seconds.
    public var tiMinSeconds: Double?

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
    /// `S.ABFilter` — is the antibacterial filter fitted?
    public var antibacterialFilter: Bool?

    public init() {}

    /// True when at least one field was successfully extracted — used
    /// by the UI to decide whether to show the empty state.
    public var hasAnyValue: Bool {
        modeCode != nil
            || cpapPressure != nil || autoMaxPressure != nil
            || bilevelIPAP != nil || vautoMaxIPAP != nil
            || eprEnabled != nil || rampEnableCode != nil
            || humidityLevel != nil || maskCode != nil
            || tiMaxSeconds != nil || tiMinSeconds != nil
            || triggerSensitivityCode != nil || cycleSensitivityCode != nil
            || antibacterialFilter != nil || riseTimeEnabled != nil
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

    /// Human label for the 0–4 trigger/cycle sensitivity scale
    /// ResMed exposes — matches the words the device itself shows
    /// (Very Low / Low / Medium / High / Very High).
    private static func sensitivityName(_ code: Int?) -> String? {
        guard let code else { return nil }
        switch code {
        case 0: return "Very Low"
        case 1: return "Low"
        case 2: return "Medium"
        case 3: return "High"
        case 4: return "Very High"
        default: return "Code \(code)"
        }
    }

    public var triggerSensitivityName: String? {
        Self.sensitivityName(triggerSensitivityCode)
    }

    public var cycleSensitivityName: String? {
        Self.sensitivityName(cycleSensitivityCode)
    }

    // MARK: - Decoding from STR.edf

    /// Decode a `DeviceSettings` from a single STR.edf record by
    /// asking the caller for scalar values keyed by signal label.
    /// Callers in `DailyStatistics.decode` already have the
    /// machinery to read one sample per signal per record — this
    /// just names the specific signals we care about. Returns `nil`
    /// when none of the signals yielded a value.
    ///
    /// `isAirSense11` switches the numeric remap used for therapy
    /// modes and a few related enum fields. AirSense/AirCurve 11
    /// firmware writes the STR.edf `Mode` signal in its own
    /// compact enum (1 = CPAP, 2 = AutoSet, 3 = AutoSet for Her);
    /// we translate those into the S9/AS10 codes the UI layer
    /// already knows how to render so the rest of the app doesn't
    /// need to grow a second mode vocabulary.
    public static func decode(
        isAirSense11: Bool = false,
        scalar: (String) -> Double?
    ) -> DeviceSettings? {
        var s = DeviceSettings()

        // Therapy
        s.modeCode = scalar("Mode").map { rawMode in
            isAirSense11 ? remapAS11Mode(Int(rawMode)) : Int(rawMode)
        }
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
        s.riseTimeEnabled = scalar("S.RiseEnable").map { $0 > 0 }
        s.riseTimeMs = scalar("S.RiseTime").map { Int($0) }

        // Bilevel / VAuto timing — same signals feed both modes.
        s.triggerSensitivityCode = scalar("S.Trigger").map { Int($0) }
        s.cycleSensitivityCode = scalar("S.Cycle").map { Int($0) }
        s.tiMaxSeconds = scalar("S.TiMax")
        s.tiMinSeconds = scalar("S.TiMin")

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
        s.antibacterialFilter = scalar("S.ABFilter").map { $0 > 0 }

        return s.hasAnyValue ? s : nil
    }

    /// Translate an AirSense 11 raw mode integer into the S9/AS10
    /// enum used everywhere else in the app. Values outside the
    /// known AS11 range pass through untouched so an unknown mode
    /// still surfaces under its original code (via the "Mode N"
    /// fallback in `modeName`) rather than silently misreporting.
    ///
    /// Known mapping, cross-referenced with OSCAR's
    /// `ResmedAS11ModeToS9Mode` table:
    ///
    ///   AS11  →  AS10
    ///   1     →  1   CPAP
    ///   2     →  3   AutoSet (APAP)
    ///   3     →  7   AutoSet for Her
    ///
    /// AirSense 11 currently ships only in CPAP / AutoSet / AutoSet
    /// for Her configurations, so higher codes are speculative; if
    /// ResMed adds a bilevel 11 variant later we'll need to expand
    /// the table.
    private static func remapAS11Mode(_ raw: Int) -> Int {
        switch raw {
        case 1: return 1 // CPAP
        case 2: return 3 // AutoSet
        case 3: return 7 // AutoSet for Her
        default: return raw
        }
    }

    /// Return a copy of `self` where any field that's currently `nil`
    /// inherits its value from `other`. Non-nil fields in `self` win,
    /// so "newer" settings stay authoritative while "older" cached
    /// settings only backfill the gaps.
    ///
    /// This matters when STR.edf is partially rewritten on the
    /// device: a later import may have a record for a given night
    /// that's missing a few S.* signals (they weren't emitted, not
    /// explicitly cleared). Without this merge we'd null those
    /// fields out on the next backfill even though we previously
    /// decoded them fine.
    public func completingNils(from other: DeviceSettings) -> DeviceSettings {
        var s = self
        s.modeCode ??= other.modeCode
        s.cpapPressure ??= other.cpapPressure
        s.cpapStartPressure ??= other.cpapStartPressure
        s.autoMinPressure ??= other.autoMinPressure
        s.autoMaxPressure ??= other.autoMaxPressure
        s.autoStartPressure ??= other.autoStartPressure
        s.autoForHerMinPressure ??= other.autoForHerMinPressure
        s.autoForHerMaxPressure ??= other.autoForHerMaxPressure
        s.autoForHerStartPressure ??= other.autoForHerStartPressure
        s.bilevelIPAP ??= other.bilevelIPAP
        s.bilevelEPAP ??= other.bilevelEPAP
        s.bilevelStartPressure ??= other.bilevelStartPressure
        s.vautoMaxIPAP ??= other.vautoMaxIPAP
        s.vautoMinEPAP ??= other.vautoMinEPAP
        s.vautoPressureSupport ??= other.vautoPressureSupport
        s.vautoStartPressure ??= other.vautoStartPressure
        s.eprEnabled ??= other.eprEnabled
        s.eprLevel ??= other.eprLevel
        s.eprTypeCode ??= other.eprTypeCode
        s.rampEnableCode ??= other.rampEnableCode
        s.rampTimeMinutes ??= other.rampTimeMinutes
        s.easyBreathe ??= other.easyBreathe
        s.smartStart ??= other.smartStart
        s.riseTimeEnabled ??= other.riseTimeEnabled
        s.riseTimeMs ??= other.riseTimeMs
        s.triggerSensitivityCode ??= other.triggerSensitivityCode
        s.cycleSensitivityCode ??= other.cycleSensitivityCode
        s.tiMaxSeconds ??= other.tiMaxSeconds
        s.tiMinSeconds ??= other.tiMinSeconds
        s.climateControlCode ??= other.climateControlCode
        s.humidityEnabled ??= other.humidityEnabled
        s.humidityLevel ??= other.humidityLevel
        s.tubeTempEnableCode ??= other.tubeTempEnableCode
        s.tubeTempCelsius ??= other.tubeTempCelsius
        s.heatedTube ??= other.heatedTube
        s.maskCode ??= other.maskCode
        s.tubeCode ??= other.tubeCode
        s.antibacterialFilter ??= other.antibacterialFilter
        return s
    }
}

/// Fill-in-if-nil operator used by `DeviceSettings.completingNils`.
/// `lhs ??= rhs` is `lhs = lhs ?? rhs` — only overwrites when `lhs`
/// was nil to begin with, which is exactly the "prefer newer,
/// backfill from older" semantics we want for the settings merge.
infix operator ??=: AssignmentPrecedence
private func ??= <T>(lhs: inout T?, rhs: T?) {
    if lhs == nil { lhs = rhs }
}
