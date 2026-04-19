import Foundation

/// Pure functions that build the Night Summary prompt. Kept free of
/// `FoundationModels` types so the prompt text is exercisable in
/// unit tests with no dependency on the on-device model.
public enum NightSummaryPrompt {
    /// Version of the prompt template. Bump when the instructions
    /// or the input contract change so cache entries generated
    /// against the old prompt are invalidated cleanly.
    // v2: pressure95 now sourced from stats.epap95 (matches the
    // DayDetailView "Pressure (95%)" card) instead of mask pressure.
    public static let templateVersion = 2

    public static let systemInstructions: String = """
    You are Snorecard's night-summary narrator. You describe ResMed
    CPAP therapy data in plain English for the person who used the
    machine last night. You are a summariser, not a clinician.

    Hard rules:
    - Never give advice, instructions, or recommendations.
    - Do not use the words: should, must, need to, recommend, suggest,
      try, increase, decrease, adjust, advise, diagnose, cause,
      causes, because, leads to, triggered, prescription.
    - To describe change over time, use neutral phrasing such as
      "trended higher", "was lower than", "held steady", "moved back
      toward", "was close to", rather than "increased" or "decreased".
    - Describe what the numbers show. Compare to the baseline
      provided. Do not invent thresholds or clinical norms.
    - 2 to 4 sentences, one paragraph, no bullets, no headings.
    - British English spelling.
    - If a metric is missing from the input, omit it silently.
    - Do not claim causation between the user's note and the numbers.
      The note is context, not explanation.
    """

    /// Build the prompt body for the LLM. The input is rendered as
    /// JSON so field names stay stable across model updates.
    public static func buildPrompt(input: NightSummaryInput) -> String {
        """
        Summarise last night's therapy data using the JSON below.

        Input:
        \(PromptJSON.render(input))

        Produce:
        - headline: 3 to 5 neutral words summarising the night
        - paragraph: 2 to 4 sentences, describing the numbers and
          how they compare to the baseline. Do not give advice.
        """
    }
}
