import Foundation

/// Whether a profile field was last set by the user typing into
/// Snorecard's Settings or by an Apple Health import. The
/// distinction matters because Health-sourced fields are
/// read-only inside Snorecard — the user has to edit them in the
/// Health app so the two stay in sync. Manual fields can be edited
/// freely on either platform and ride iCloud KVS to the other.
public enum ProfileFieldSource: String, Codable, Sendable, Equatable {
    case manual
    case healthKit
}

/// User-supplied therapy prescription details. Snorecard never
/// imports these — they live with the patient, not the device, and
/// no exposed Health API surfaces them — so every field is
/// editable on both platforms. `mode` drives whether the UI shows
/// a single fixed pressure or a min/max range.
public struct UserProfilePrescription: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable, Equatable {
        case cpap
        case apap
        case bipap
        case asv

        public var id: String { rawValue }

        /// Long form for pickers and prose. Keep symmetric with
        /// `DeviceType.displayName` so the prescription mode reads
        /// the same as the user's device-type selection elsewhere.
        public var displayName: String {
            switch self {
            case .cpap:  return "CPAP"
            case .apap:  return "APAP"
            case .bipap: return "BiPAP"
            case .asv:   return "ASV"
            }
        }
    }

    /// Therapy mode the prescription specifies. Drives the UI's
    /// single-pressure-vs-range branching.
    public var mode: Mode
    /// Lower bound of the prescribed pressure range, in cmH2O. For
    /// fixed-pressure CPAP this is the only pressure field used —
    /// the UI hides `pressureMax` and treats this as "the
    /// prescribed pressure".
    public var pressureMin: Double?
    /// Upper bound of the prescribed pressure range, in cmH2O.
    /// Only meaningful for auto-titrating modes (APAP, BiPAP-auto,
    /// ASV); the UI hides this for plain CPAP.
    public var pressureMax: Double?
    /// Bilevel pressure support delta or EPR level, in cmH2O — the
    /// difference between IPAP and EPAP for bilevel modes, or the
    /// EPR drop for CPAP/APAP. Optional because not every
    /// prescription specifies one.
    public var pressureSupport: Double?
    /// Free-form notes (clinician name, prescription date, mask
    /// recommendation, anything else worth carrying).
    public var notes: String?

    public init(
        mode: Mode = .cpap,
        pressureMin: Double? = nil,
        pressureMax: Double? = nil,
        pressureSupport: Double? = nil,
        notes: String? = nil
    ) {
        self.mode = mode
        self.pressureMin = pressureMin
        self.pressureMax = pressureMax
        self.pressureSupport = pressureSupport
        self.notes = notes
    }

    /// `true` when the prescription has at least one numeric value
    /// or note set — used by the UI to decide whether to render a
    /// "Not set" placeholder vs the populated fields.
    public var hasAnyValue: Bool {
        if pressureMin != nil { return true }
        if pressureMax != nil { return true }
        if pressureSupport != nil { return true }
        if let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty { return true }
        return false
    }
}

/// Per-user profile carried alongside a Snorecard install.
/// Lives on `Library`, persisted via `NSUbiquitousKeyValueStore`
/// so the same fields populate on every device the user signs in
/// to. Health-sourced fields (`heightCm`, `weightKg`) follow Apple
/// Health as source of truth: when imported, the UI marks them
/// read-only and points the user back to Health.app for edits.
public struct UserProfile: Codable, Sendable, Equatable {
    /// Display name. Apple HealthKit doesn't expose the user's
    /// Medical-ID name to third-party apps, so this stays manual
    /// on every platform.
    public var name: String?
    /// Height in centimetres. Persisted in metric so the value
    /// round-trips losslessly with Apple Health regardless of the
    /// user's display preference; the UI converts to imperial
    /// when the locale calls for it.
    public var heightCm: Double?
    /// Body mass in kilograms. Same metric-internal rationale as
    /// `heightCm`.
    public var weightKg: Double?
    /// Where `heightCm` came from. `.healthKit` means the user
    /// imported it from Health; the field is read-only in
    /// Snorecard until the user explicitly switches to manual.
    public var heightSource: ProfileFieldSource
    /// Where `weightKg` came from — same semantics as `heightSource`.
    public var weightSource: ProfileFieldSource
    /// Active CPAP / bilevel prescription details, if known. `nil`
    /// when the user hasn't filled any of the prescription fields
    /// in Settings.
    public var prescription: UserProfilePrescription?
    /// Untreated AHI from the user's diagnostic sleep study, in
    /// events per hour. Useful as a long-running anchor so the
    /// user can see "how bad was it before therapy started".
    public var untreatedAHI: Double?
    /// Date the user was diagnosed with sleep apnoea. Stored as a
    /// calendar-day-precision date.
    public var diagnosisDate: Date?

    public init(
        name: String? = nil,
        heightCm: Double? = nil,
        weightKg: Double? = nil,
        heightSource: ProfileFieldSource = .manual,
        weightSource: ProfileFieldSource = .manual,
        prescription: UserProfilePrescription? = nil,
        untreatedAHI: Double? = nil,
        diagnosisDate: Date? = nil
    ) {
        self.name = name
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.heightSource = heightSource
        self.weightSource = weightSource
        self.prescription = prescription
        self.untreatedAHI = untreatedAHI
        self.diagnosisDate = diagnosisDate
    }

    /// Empty profile — every field nil, both sources defaulting to
    /// `.manual` so a fresh-install user editing fields gets the
    /// expected behaviour without first having to "switch off"
    /// HealthKit sourcing.
    public static let empty = UserProfile()

    /// `true` when every visible field is unset — used by the
    /// Settings UI to decide whether to show an empty-state
    /// "Tell us about yourself" placeholder.
    public var isEmpty: Bool {
        if name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return false
        }
        if heightCm != nil { return false }
        if weightKg != nil { return false }
        if prescription?.hasAnyValue == true { return false }
        if untreatedAHI != nil { return false }
        if diagnosisDate != nil { return false }
        return true
    }
}
