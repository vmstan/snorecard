import Foundation

/// Utility rounding primitives used by prompt input builders and
/// the `TagCorrelator` so canonical representations line up with
/// the hashes stored in `IntelligenceCache`.
///
/// (This file previously also held `PromptJSON`, which rendered
/// input structs as JSON for embedding in prompts. Prompts now
/// use plain-English `promptDescription` accessors on each input
/// type instead — field names like `leak95LPerMin` had a habit
/// of bleeding into the model's narration when it echoed the
/// keys it had been shown.)
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
