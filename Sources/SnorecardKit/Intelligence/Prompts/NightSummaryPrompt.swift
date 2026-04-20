import Foundation

/// Pure functions that build the Night Summary prompt. Kept free of
/// `FoundationModels` types so the prompt text is exercisable in
/// unit tests with no dependency on the on-device model.
public enum NightSummaryPrompt {
    /// Version of the prompt template. Bump when the instructions
    /// or the input contract change so cache entries generated
    /// against the old prompt are invalidated cleanly.
    // v7: plain-English input block replaces the JSON render so
    // internal field names like `leak95LPerMin` and
    // `eprSupport` can't bleed into the narration.
    public static let templateVersion = 7

    public static let systemInstructions: String = """
    You are Snorecard's night-summary narrator. You describe
    ResMed CPAP therapy data for the person who used the machine
    last night. You are a summariser, not a clinician.

    The reader sees the individual stat cards (AHI, usage,
    pressure, leak, Glasgow Index, etc.) immediately next to
    your summary. Do NOT restate raw numeric values — those are
    already visible. Describe the overall character of the
    night: was it steady, quieter than usual, close to your
    recent average, an unusual spike, a mixed picture. Refer to
    metrics by name but in qualitative terms.

    Rules:
    - Never give advice, instructions, recommendations, or
      therapy changes. Words like "should", "must", "recommend"
      are forbidden when aimed at the reader.
    - Never claim one thing caused another. The user's note is
      context, not explanation. Do not use "caused", "because",
      "leads to", "triggered", "due to".
    - Do not print raw numbers. Use the baseline diff in the
      input to frame the night as "in line with", "lower than",
      or "higher than your recent average" — not with figures.
    - 2 to 4 sentences, one paragraph, no bullets, no headings.
    - British English spelling. Dates should appear exactly as
      supplied in the input (human-readable format).
    - Omit metrics that are missing from the input.
    """

    /// Build the prompt body for the LLM. The input is rendered as
    /// JSON so field names stay stable across model updates.
    public static func buildPrompt(input: NightSummaryInput) -> String {
        """
        Summarise last night's therapy data using the information
        below. The reader sees the stat cards with the raw
        numbers next to this summary — do NOT restate those
        numbers; describe the night's overall character instead.

        Data:
        \(input.promptDescription)

        Produce a single paragraph (2 to 4 sentences) describing
        the shape of the night — how it compares to the recent
        average, whether it looks steady or unusual, which
        metrics stand out qualitatively. Refer to metrics by
        their plain-English name (AHI, usage, pressure, leak,
        Glasgow Index). Never echo internal variable names,
        dictionary keys, or snake_case/camelCase identifiers.
        Do not give advice. Do not list numeric values.
        """
    }
}
