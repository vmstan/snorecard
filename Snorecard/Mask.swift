import Foundation

/// One physical mask the user wears at night. Curated by the user in
/// Settings → Mask, persisted as a JSON-encoded array under a single
/// `NSUbiquitousKeyValueStore` key so the catalog rides iCloud across
/// every device the user signs into. Per-session mask assignments
/// live separately on each day's `.snorecard-notes.json` sidecar via
/// `DailyNote.sessionMasks` — only the catalog and the
/// "default for new imports" pointer live in KVS.
///
/// `String` raw values on the three pickers are versioned forever:
/// once shipped, an existing device may have a mask referencing
/// `"fullFace"` etc. in its synced KVS payload. Renaming a case would
/// silently invalidate that reference, so the human-readable label
/// is split out into `displayName` and the raw value never moves.
struct Mask: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var manufacturer: MaskManufacturer
    /// User-supplied brand name when `manufacturer == .other`. Trimmed
    /// of whitespace before persistence; `nil` (or empty after trim)
    /// is allowed and falls back to the literal "Other" label in UI.
    var customManufacturer: String?
    /// Freeform model name. The CPAP-mask model space is too large
    /// and too churning to enumerate, so this stays a plain
    /// `TextField` rather than a curated picker.
    var model: String
    var type: MaskType
    var size: MaskSize

    init(
        id: UUID = UUID(),
        manufacturer: MaskManufacturer,
        customManufacturer: String? = nil,
        model: String,
        type: MaskType,
        size: MaskSize
    ) {
        self.id = id
        self.manufacturer = manufacturer
        self.customManufacturer = customManufacturer
        self.model = model
        self.type = type
        self.size = size
    }

    /// Brand string the UI should render. Prefers the user's
    /// `customManufacturer` only when `.other` is selected and the
    /// custom field has non-whitespace content; everything else
    /// resolves to the canonical `displayName` of the picked
    /// manufacturer.
    var manufacturerLabel: String {
        if manufacturer == .other,
           let custom = customManufacturer?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return manufacturer.displayName
    }

    /// One-line label used in mask-list rows and the per-session
    /// menu. Drops empty model strings gracefully so a half-filled
    /// mask record still reads sensibly.
    var displayLabel: String {
        let trimmedModel = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmedModel.isEmpty
            ? manufacturerLabel
            : "\(manufacturerLabel) \(trimmedModel)"
        return "\(head) — \(size.displayName)"
    }

    /// Compact two-token label used inside narrow `SessionListSheet`
    /// rows where the full `displayLabel` doesn't fit. Pairs the
    /// brand abbreviation with the size chip — enough for the user
    /// to recognise which mask is on a given session at a glance.
    var compactLabel: String {
        "\(manufacturer.shortName) \(size.displayName)"
    }
}

/// CPAP-mask brand the user picks for a `Mask`. Order in
/// `allCases` is the order shown in the picker, so it tracks the
/// market-share-ish ordering the user asked for at design time.
enum MaskManufacturer: String, Codable, CaseIterable, Identifiable, Sendable {
    case resmed
    case philipsRespironics
    case fisherPaykel
    case bleep
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .resmed:             return "ResMed"
        case .philipsRespironics: return "Philips Respironics"
        case .fisherPaykel:       return "Fisher & Paykel"
        case .bleep:              return "Bleep"
        case .other:              return "Other"
        }
    }

    /// Short brand token used by `Mask.compactLabel` so the per-session
    /// row can fit on iPhone-narrow widths without truncation.
    var shortName: String {
        switch self {
        case .resmed:             return "ResMed"
        case .philipsRespironics: return "Philips"
        case .fisherPaykel:       return "F&P"
        case .bleep:              return "Bleep"
        case .other:              return "Other"
        }
    }
}

enum MaskType: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullFace
    case nasal
    case pillow
    case hybrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullFace: return "Full Face"
        case .nasal:    return "Nasal"
        case .pillow:   return "Pillow"
        case .hybrid:   return "Hybrid"
        }
    }
}

/// Mask sizes the user picks from. Two dual-letter sizes exist
/// because most major manufacturers ship "S/M" and "M/L" frames
/// alongside the discrete S/M/L singletons; mixing them in one
/// picker keeps the user from having to invent a convention for
/// frames whose box literally says "S/M".
enum MaskSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case xs
    case s
    case sm
    case m
    case ml
    case l
    case xl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .xs: return "XS"
        case .s:  return "S"
        case .sm: return "S/M"
        case .m:  return "M"
        case .ml: return "M/L"
        case .l:  return "L"
        case .xl: return "XL"
        }
    }
}
