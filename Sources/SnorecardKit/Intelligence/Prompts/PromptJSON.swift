import Foundation

/// Shared helper for rendering prompt input structs into stable
/// canonical JSON that's safe to embed in a prompt string. Keys are
/// sorted so prompt hashing stays deterministic; dates are encoded
/// as ISO-8601; nil values are omitted (the prompt instructions
/// tell the model to skip missing fields).
enum PromptJSON {
    /// Human-readable date formatter used when rendering inputs
    /// into prompts — the model is likelier to echo whatever it
    /// sees verbatim than to reformat an ISO-8601 string, and
    /// we'd rather a narrative say "17 April 2026" than
    /// "2026-04-17T05:00:00Z". British English locale to match
    /// the prompt's spelling rule. Note: `IntelligenceCache.hash`
    /// uses its own ISO-8601 encoder so cache keys stay stable
    /// regardless of this formatter's output.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .formatted(dateFormatter)
        return encoder
    }()

    /// Render `value` as a pretty-printed, sorted-keys JSON block
    /// suitable for embedding in a prompt. Falls back to a brace
    /// placeholder on encode failure so the surrounding prompt
    /// text stays syntactically intact.
    static func render(_ value: some Encodable) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

/// Utility rounding primitives used by every prompt builder so
/// canonical representations line up with cache keys.
enum PromptRounding {
    static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func toInt(_ value: Double) -> Int {
        Int(value.rounded())
    }
}
