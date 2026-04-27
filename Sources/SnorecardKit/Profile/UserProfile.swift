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

/// Biological sex as Apple Health's Medical-ID surfaces it, mirrored
/// here so the model stays HealthKit-free. The `HKBiologicalSex.notSet`
/// case maps to `nil` rather than its own enum member — "the user
/// hasn't recorded a value" is the same idea on both sides of the
/// import.
public enum BiologicalSex: String, Codable, Sendable, CaseIterable, Identifiable, Equatable {
    case female
    case male
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .female: return "Female"
        case .male:   return "Male"
        case .other:  return "Other"
        }
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
    /// Biological sex from the user's Apple Health Medical ID, or
    /// the manual override they typed in Snorecard.
    public var biologicalSex: BiologicalSex?
    /// Where `biologicalSex` came from — same `.healthKit` /
    /// `.manual` semantics as `heightSource`.
    public var biologicalSexSource: ProfileFieldSource
    /// Date of birth from the user's Apple Health Medical ID, or a
    /// manual override. Stored at calendar-day precision; the UI
    /// derives age from it rather than storing age directly so the
    /// number doesn't go stale on a birthday.
    public var dateOfBirth: Date?
    /// Where `dateOfBirth` came from — same semantics as
    /// `heightSource`.
    public var dateOfBirthSource: ProfileFieldSource
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
        biologicalSex: BiologicalSex? = nil,
        biologicalSexSource: ProfileFieldSource = .manual,
        dateOfBirth: Date? = nil,
        dateOfBirthSource: ProfileFieldSource = .manual,
        untreatedAHI: Double? = nil,
        diagnosisDate: Date? = nil
    ) {
        self.name = name
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.heightSource = heightSource
        self.weightSource = weightSource
        self.biologicalSex = biologicalSex
        self.biologicalSexSource = biologicalSexSource
        self.dateOfBirth = dateOfBirth
        self.dateOfBirthSource = dateOfBirthSource
        self.untreatedAHI = untreatedAHI
        self.diagnosisDate = diagnosisDate
    }

    /// Convenience for the UI — current age in whole years derived
    /// from `dateOfBirth`. Returns `nil` if DOB isn't set or sits in
    /// the future.
    public var ageYears: Int? {
        guard let dob = dateOfBirth else { return nil }
        let years = Calendar.current.dateComponents([.year], from: dob, to: Date()).year
        guard let years, years >= 0 else { return nil }
        return years
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
        if biologicalSex != nil { return false }
        if dateOfBirth != nil { return false }
        if untreatedAHI != nil { return false }
        if diagnosisDate != nil { return false }
        return true
    }
}
