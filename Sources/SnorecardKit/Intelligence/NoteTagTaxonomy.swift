import Foundation
import FoundationModels

/// Closed set of tags that the note-extraction pass is allowed to
/// emit. Keeping this as a `@Generable` enum means the on-device
/// model physically cannot invent new labels — the decoder only
/// accepts one of these cases.
///
/// The taxonomy is versioned via `NoteTagTaxonomy.version`. Bumping
/// the version invalidates every cached `DailyNote.extractedTags`
/// on next read and triggers a re-extraction.
@Generable
public enum NoteTag: String, Codable, Hashable, Sendable, CaseIterable {
    // Respiratory / physiology
    case congestion
    case allergies
    case illness
    case mouthBreathing
    case nasalBlocked

    // Substances / timing
    case alcohol
    case lateCaffeine
    case lateMeal
    case medicationChange

    // Environment / context
    case travel
    case hotelBed
    case highAltitude
    case roomTooWarm
    case kidsInBed
    case petsInBed

    // Equipment
    case newMask
    case maskLeak
    case humidifierTweak
    case vCom
    case mouthTape
    case neckBrace

    // Sleep hygiene
    case stress
    case lateNight
    case napToday
    case exercised
    case lateExercise

    // Sleeping position
    case sleepingOnBack
    case sleepingOnSide

    /// Short display label surfaced in chip UI on the Trends
    /// correlation card. Ordering of `allCases` is the order chips
    /// appear when multiple tags fire together.
    public var displayLabel: String {
        switch self {
        case .congestion:       return "Congestion"
        case .allergies:        return "Allergies"
        case .illness:          return "Illness"
        case .mouthBreathing:   return "Mouth breathing"
        case .nasalBlocked:     return "Nasal block"
        case .alcohol:          return "Alcohol"
        case .lateCaffeine:     return "Late caffeine"
        case .lateMeal:         return "Late meal"
        case .medicationChange: return "Medication change"
        case .travel:           return "Travel"
        case .hotelBed:         return "Hotel bed"
        case .highAltitude:     return "High altitude"
        case .roomTooWarm:      return "Room too warm"
        case .kidsInBed:        return "Kids in bed"
        case .petsInBed:        return "Pets in bed"
        case .newMask:          return "New mask"
        case .maskLeak:         return "Mask leak"
        case .humidifierTweak:  return "Humidifier tweak"
        case .vCom:             return "V-com"
        case .mouthTape:        return "Mouth tape"
        case .neckBrace:        return "Neck brace"
        case .stress:           return "Stress"
        case .lateNight:        return "Late night"
        case .napToday:         return "Nap today"
        case .exercised:        return "Exercised today"
        case .lateExercise:     return "Late exercise"
        case .sleepingOnBack:   return "Slept on back"
        case .sleepingOnSide:   return "Slept on side"
        }
    }

    /// Category the tag belongs to, used by the manual tag picker
    /// in `NotesCard` to group the 22-tag list into meaningful
    /// sections instead of a flat scroll.
    public var category: NoteTagCategory {
        switch self {
        case .congestion, .allergies, .illness,
             .mouthBreathing, .nasalBlocked:
            return .respiratory
        case .alcohol, .lateCaffeine, .lateMeal, .medicationChange:
            return .substances
        case .travel, .hotelBed, .highAltitude, .roomTooWarm,
             .kidsInBed, .petsInBed:
            return .environment
        case .newMask, .maskLeak, .humidifierTweak,
             .vCom, .mouthTape, .neckBrace:
            return .equipment
        case .stress, .lateNight, .napToday,
             .exercised, .lateExercise:
            return .sleepHygiene
        case .sleepingOnBack, .sleepingOnSide:
            return .position
        }
    }
}

/// Ordered grouping for the manual tag picker. Cases are declared
/// in the order they should appear in the menu.
public enum NoteTagCategory: String, CaseIterable, Sendable {
    case respiratory
    case substances
    case environment
    case equipment
    case sleepHygiene
    case position

    /// Heading shown above the tag list for this category.
    public var displayLabel: String {
        switch self {
        case .respiratory:  return "Respiratory"
        case .substances:   return "Substances & Timing"
        case .environment:  return "Environment"
        case .equipment:    return "Equipment"
        case .sleepHygiene: return "Sleep Hygiene"
        case .position:     return "Sleeping Position"
        }
    }

    /// Tags that belong to this category, in taxonomy order.
    public var tags: [NoteTag] {
        NoteTag.allCases.filter { $0.category == self }
    }
}

/// Taxonomy metadata. The version is embedded in every cached
/// `DailyNote.extractedTags` payload so a future taxonomy change
/// invalidates old tags without requiring a manual migration.
public enum NoteTagTaxonomy {
    /// Bump whenever `NoteTag` cases are added, renamed, or removed.
    /// v2: added `kidsInBed`, `petsInBed`, `exercised`,
    /// `lateExercise`. v3: added `vCom`, `mouthTape`, `neckBrace`
    /// under equipment so accessories show up alongside mask /
    /// humidifier events. Existing cached `DailyNote.extractedTags`
    /// generated against an earlier version will re-run on next
    /// read so the new cases have a chance to fire against older
    /// notes.
    public static let version = 3

    /// Hard cap on tags per note. The prompt asks for "up to 4" but
    /// we also truncate in Swift as a belt-and-braces guard.
    public static let maxTagsPerNote = 4
}

public struct NoteTagInput: Codable, Hashable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

@Generable
public struct NoteTagsOutput: Codable, Hashable, Sendable {
    @Guide(description: "Up to 4 tags. Each tag must describe something the note text explicitly mentions. Do not infer from absence. Empty array is allowed.")
    public let tags: [NoteTag]

    public init(tags: [NoteTag]) {
        self.tags = tags
    }
}
