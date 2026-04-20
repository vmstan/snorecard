import Foundation

/// Post-generation sanity checks. Any output containing a banned
/// phrase is treated as a rejection — the view that requested the
/// narrative hides the card rather than rendering
/// advisory/diagnostic language. The model's prompt also forbids
/// these tokens, but post-checking in Swift is a belt-and-braces
/// guard against prompt drift, jailbreaks, or model updates.
public enum Guardrails {
    /// Categories of banned phrasing. Exposed so tests can assert
/// which bucket a rejected phrase fell into.
    public enum Violation: String, Sendable, Equatable {
        /// Prescriptive modals or imperatives (e.g. "you should").
        case prescriptive
        /// Causal claims ("caused", "leads to", "because").
        case causal
        /// Medical/diagnostic framing ("diagnose", "prescription").
        case medical
    }

    public enum Verdict: Sendable, Equatable {
        case accepted
        case rejected(Violation, match: String)
    }

    /// Whole-word banned tokens — matched case-insensitively at
    /// word boundaries so "cause" in "because" doesn't double-trip,
    /// but "should" inside "You should" does.
    ///
    /// Scoped to unambiguously advisory framings. Previous versions
    /// also listed "try", "increase", "decrease", "adjust", and
    /// "suggest", but all of those have a perfectly legitimate
    /// descriptive sense ("an increase in AHI", "these numbers
    /// suggest stable therapy") that a word-level filter can't
    /// tell apart from imperatives — which kept rejecting fine
    /// output and hiding the card. The words below have no such
    /// ambiguity; they are always directives aimed at the reader.
    /// The prompt's "never give advice" rule handles the rest.
    private static let prescriptiveWords: [String] = [
        "should", "must", "need to", "needs to", "ought to",
        "recommend", "recommends", "recommended",
        "advise", "advises", "advised"
    ]

    /// Causal-claim words. "makes"/"made" were removed because
    /// they're ambiguous in descriptive prose ("this made the
    /// week's data look noisy") and kept false-tripping otherwise
    /// fine summaries. The remaining list still catches every
    /// concrete causal claim form the model tends to produce.
    private static let causalWords: [String] = [
        "caused", "causes", "causing",
        "leads to", "led to",
        "because", "due to",
        "triggered", "triggers"
    ]

    private static let medicalWords: [String] = [
        "diagnose", "diagnoses", "diagnosed", "diagnosis",
        "prescription", "prescribes", "prescribed",
        "dosage"
    ]

    /// Scan `text` for banned phrases and return the first
    /// violation found. Empty/whitespace input is accepted (the
    /// caller is expected to decide separately whether to render
    /// an empty card — this helper only polices content).
    public static func evaluate(_ text: String) -> Verdict {
        let haystack = text.lowercased()
        if let hit = firstMatch(in: haystack, needles: prescriptiveWords) {
            return .rejected(.prescriptive, match: hit)
        }
        if let hit = firstMatch(in: haystack, needles: causalWords) {
            return .rejected(.causal, match: hit)
        }
        if let hit = firstMatch(in: haystack, needles: medicalWords) {
            return .rejected(.medical, match: hit)
        }
        return .accepted
    }

    /// Convenience: run `evaluate` over every non-optional string in
    /// the supplied collection and return the first violation, or
    /// `.accepted` if every field passes.
    public static func evaluateAll(_ fields: [String]) -> Verdict {
        for field in fields {
            let verdict = evaluate(field)
            if case .rejected = verdict { return verdict }
        }
        return .accepted
    }

    private static func firstMatch(in haystack: String, needles: [String]) -> String? {
        for needle in needles {
            if containsAsWord(haystack, needle: needle) {
                return needle
            }
        }
        return nil
    }

    /// Word-boundary substring check — matches `needle` only when
    /// it's not embedded inside a larger alphabetic word. Uses
    /// simple ASCII-letter boundary detection, which is sufficient
    /// for an English-only ruleset.
    private static func containsAsWord(_ haystack: String, needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let before: Character? = range.lowerBound > haystack.startIndex
                ? haystack[haystack.index(before: range.lowerBound)]
                : nil
            let after: Character? = range.upperBound < haystack.endIndex
                ? haystack[range.upperBound]
                : nil
            if !isWordCharacter(before) && !isWordCharacter(after) {
                return true
            }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ ch: Character?) -> Bool {
        guard let ch else { return false }
        return ch.isLetter
    }
}
