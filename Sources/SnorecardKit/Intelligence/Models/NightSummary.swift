import Foundation
import FoundationModels

/// Structured input for the per-night summary prompt. All numeric
/// fields are canonicalised (rounded to the precision listed in the
/// plan) before being hashed for the cache key, so tiny float drift
/// between iCloud syncs doesn't invalidate an otherwise identical
/// entry.
public struct NightSummaryInput: Codable, Hashable, Sendable {
    public let date: Date
    public let usageHours: Double          // 1 dp
    public let ahi: Double                 // 1 dp
    public let glasgowIndex: Double?       // 2 dp
    public let pressure95: Double?         // 1 dp
    public let eprSupport: Double?         // 1 dp  (ipap95 − epap95)
    public let leak95LPerMin: Int?         // integer
    public let largeLeakPercent: Double?   // 1 dp
    public let timeInApneaPercent: Double? // 1 dp
    public let tidalVolumeMedianML: Int?   // integer
    public let baselineDiff: BaselineDiff?
    public let userNote: String?
    /// User's subjective rating for the night on a 1–5 scale, or
    /// `nil` when they haven't rated it. Surfaced so the narrative
    /// can acknowledge "you rated this a 4/5" without inventing a
    /// rating the user never provided.
    public let subjectiveScore: Int?
    /// Tags the user (or the extraction pass) has associated with
    /// the night, in display-label form. Empty when neither is
    /// present. Rendered as a comma-separated line so the model
    /// treats them as context, not fields to echo verbatim.
    public let userTags: [String]

    public struct BaselineDiff: Codable, Hashable, Sendable {
        public let ahiDelta: Double        // 1 dp, signed
        public let usageHoursDelta: Double // 1 dp, signed
        public let leakDelta: Double?      // 1 dp, signed
        public let giDelta: Double?        // 2 dp, signed

        public init(
            ahiDelta: Double,
            usageHoursDelta: Double,
            leakDelta: Double?,
            giDelta: Double?
        ) {
            self.ahiDelta = ahiDelta
            self.usageHoursDelta = usageHoursDelta
            self.leakDelta = leakDelta
            self.giDelta = giDelta
        }
    }

    public init(
        date: Date,
        usageHours: Double,
        ahi: Double,
        glasgowIndex: Double?,
        pressure95: Double?,
        eprSupport: Double?,
        leak95LPerMin: Int?,
        largeLeakPercent: Double?,
        timeInApneaPercent: Double?,
        tidalVolumeMedianML: Int?,
        baselineDiff: BaselineDiff?,
        userNote: String?,
        subjectiveScore: Int? = nil,
        userTags: [String] = []
    ) {
        self.date = date
        self.usageHours = usageHours
        self.ahi = ahi
        self.glasgowIndex = glasgowIndex
        self.pressure95 = pressure95
        self.eprSupport = eprSupport
        self.leak95LPerMin = leak95LPerMin
        self.largeLeakPercent = largeLeakPercent
        self.timeInApneaPercent = timeInApneaPercent
        self.tidalVolumeMedianML = tidalVolumeMedianML
        self.baselineDiff = baselineDiff
        self.userNote = userNote
        self.subjectiveScore = subjectiveScore
        self.userTags = userTags
    }
}

extension NightSummaryInput {
    /// Human-readable, natural-language rendering of the input
    /// for embedding in a prompt. JSON-style field names like
    /// `leak95LPerMin` used to leak into the narrative when the
    /// model echoed keys it had been shown, so the prompt now
    /// sees plain English labels only.
    ///
    /// The `Codable` conformance is still used for cache hashing
    /// in `IntelligenceCache.hash(of:)` — that encoder is
    /// separate and keeps stable ISO-8601 / raw-key formatting
    /// so cache identity doesn't shift when we tweak prompt
    /// prose.
    public var promptDescription: String {
        var lines: [String] = []
        lines.append("Night: \(Self.nightFormatter.string(from: date))")
        lines.append("Usage: \(formatOneDp(usageHours)) hours")
        lines.append("AHI: \(formatOneDp(ahi)) events per hour")
        if let gi = glasgowIndex {
            lines.append("Glasgow Index: \(formatTwoDp(gi))")
        }
        if let epap = pressure95 {
            lines.append("EPAP (95th percentile target): \(formatOneDp(epap)) cmH2O")
            // Derive IPAP from the EPAP baseline + the stored
            // support delta so the model sees both sides of the
            // breath cycle separately. Suppress the IPAP line
            // when the delta is negligible (CPAP therapy / EPR
            // off) — the UI card hides its IPAP subtitle in that
            // case and the prompt should match.
            if let support = eprSupport, support > 0.05 {
                let ipap = epap + support
                lines.append("IPAP (95th percentile target): \(formatOneDp(ipap)) cmH2O")
            }
        }
        if let leak = leak95LPerMin {
            lines.append("Leak (95th percentile): \(leak) L/min")
        }
        if let large = largeLeakPercent {
            lines.append("Time above 24 L/min leak: \(formatOneDp(large))% of usage")
        }
        if let apnea = timeInApneaPercent {
            lines.append("Time in apnea events: \(formatOneDp(apnea))% of usage")
        }
        if let tv = tidalVolumeMedianML {
            lines.append("Tidal volume (median): \(tv) mL")
        }

        var body = lines.map { "- \($0)" }.joined(separator: "\n")

        if let diff = baselineDiff {
            var diffLines: [String] = []
            diffLines.append("AHI change: \(formatSignedOneDp(diff.ahiDelta)) events/hr")
            diffLines.append("Usage change: \(formatSignedOneDp(diff.usageHoursDelta)) hours")
            if let leakDelta = diff.leakDelta {
                diffLines.append("Leak change: \(formatSignedOneDp(leakDelta)) L/min")
            }
            if let giDelta = diff.giDelta {
                diffLines.append("Glasgow Index change: \(formatSignedTwoDp(giDelta))")
            }
            body += "\n\nChange versus the trailing 14-day average:\n"
                + diffLines.map { "- \($0)" }.joined(separator: "\n")
        }

        if let score = subjectiveScore {
            body += "\n\nYour subjective rating for the night: "
                + "\(score) out of 5."
        }

        if !userTags.isEmpty {
            body += "\n\nContext tags you attached to the night: "
                + userTags.joined(separator: ", ") + "."
        }

        if let note = userNote {
            body += "\n\nUser's journal entry for the night:\n\"\(note)\""
        }

        return body
    }

    private static let nightFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter
    }()
}

private func formatOneDp(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func formatTwoDp(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func formatSignedOneDp(_ value: Double) -> String {
    let sign = value > 0 ? "+" : (value < 0 ? "−" : "±")
    return "\(sign)\(String(format: "%.1f", abs(value)))"
}

private func formatSignedTwoDp(_ value: Double) -> String {
    let sign = value > 0 ? "+" : (value < 0 ? "−" : "±")
    return "\(sign)\(String(format: "%.2f", abs(value)))"
}

/// On-device LLM output for the night-summary feature. Decoded via the
/// `@Generable` Foundation Models pipeline.
///
/// The card's title is a fixed string ("Sleep Analysis") on the
/// view side, so the model only needs to produce the paragraph.
/// Narrower output schema means less generation, less context
/// budget, and fewer surfaces the guardrail can reject.
@Generable
public struct NightSummaryOutput: Codable, Hashable, Sendable {
    @Guide(description: "One paragraph, 2 to 4 sentences, plain English, British spelling. Describe what the numbers show compared to the baseline. No advice, no recommendations, no causal claims.")
    public let paragraph: String

    public init(paragraph: String) {
        self.paragraph = paragraph
    }
}
