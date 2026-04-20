import Foundation

/// Pure functions that build the Night Summary prompt. Kept free of
/// `FoundationModels` types so the prompt text is exercisable in
/// unit tests with no dependency on the on-device model.
public enum NightSummaryPrompt {
    /// Version of the prompt template. Bump when the instructions
    /// or the input contract change so cache entries generated
    /// against the old prompt are invalidated cleanly.
    // v4: dropped "suggest" from the banned-words mention — the
    // model uses it legitimately in descriptive framings ("these
    // numbers suggest steady therapy") and the guardrail kept
    // rejecting otherwise safe output.
    public static let templateVersion = 4

    public static let systemInstructions: String = """
    You are Snorecard's night-summary narrator. You describe ResMed
    CPAP therapy data in plain English for the person who used the
    machine last night. You are a summariser, not a clinician.

    Rules:
    - Never give advice, instructions, recommendations, or therapy
      changes. Words like "should", "must", "recommend" are
      forbidden when aimed at the reader.
    - Never claim one thing caused another. The user's note is
      context, not explanation. Do not use "caused", "because",
      "leads to", "triggered", "due to".
    - Describe what the numbers show. Compare to the baseline
      provided. Do not invent thresholds or clinical norms.
    - 2 to 4 sentences, one paragraph, no bullets, no headings.
    - British English spelling.
    - If a metric is missing from the input, omit it silently.
    - Describing a number going up or down is fine ("AHI was lower
      than your average", "leak trended higher"). Naming an action
      for the user is not.
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
