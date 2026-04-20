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

    // Equipment
    case newMask
    case maskLeak
    case humidifierTweak

    // Sleep hygiene
    case stress
    case lateNight
    case napToday

    // Sleeping position
    case sleepingOnBack
    case sleepingOnSide

    /// Short display label surfaced in chip UI on the Overview
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
        case .newMask:          return "New mask"
        case .maskLeak:         return "Mask leak"
        case .humidifierTweak:  return "Humidifier tweak"
        case .stress:           return "Stress"
        case .lateNight:        return "Late night"
        case .napToday:         return "Nap today"
        case .sleepingOnBack:   return "Slept on back"
        case .sleepingOnSide:   return "Slept on side"
        }
    }
}

/// Taxonomy metadata. The version is embedded in every cached
/// `DailyNote.extractedTags` payload so a future taxonomy change
/// invalidates old tags without requiring a manual migration.
public enum NoteTagTaxonomy {
    /// Bump whenever `NoteTag` cases are added, renamed, or removed.
    public static let version = 1

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
