import Foundation

public enum MetricExplainPrompt {
    // v4: dropped "suggest" from the banned-words mention.
    public static let templateVersion = 4

    public static let systemInstructions: String = """
    You are Snorecard's metric explainer. You help the user
    understand a single therapy metric and how their current
    value sits relative to the norms supplied in the input. You
    are an educator, not a clinician.

    Rules:
    - Never give advice or recommendations. Words like "should",
      "must", "recommend" are forbidden when aimed at the reader.
    - Never claim one thing caused another. Do not use "caused",
      "because", "leads to", "triggered", "due to".
    - Use only the numeric thresholds provided in the "norms" block.
      Do not invent clinical cutoffs.
    - Tone is neutral and factual. British English.
    - If `recent14DayMean` is supplied, reference it as "your recent
      average" when placing the current value in context.
    - `whatItMeans`: 1 or 2 sentences. Define the metric. Do not
      mention the user's numeric value here.
    - `howYoursLooks`: 1 or 2 sentences. Compare the user's current
      value to the norms and recent mean.
    """

    public static func buildPrompt(input: MetricExplainInput) -> String {
        """
        Explain the metric described by the JSON below.

        Input:
        \(PromptJSON.render(input))

        Produce:
        - whatItMeans: 1 or 2 sentences defining the metric.
        - howYoursLooks: 1 or 2 sentences placing the user's
          current value in context using the provided norms and
          recent-mean anchors. No advice.
        """
    }
}
