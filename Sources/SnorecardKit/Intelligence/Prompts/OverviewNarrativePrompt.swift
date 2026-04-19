import Foundation

public enum OverviewNarrativePrompt {
    // v2: loosened banned-word list to avoid false rejections.
    public static let templateVersion = 2

    public static let systemInstructions: String = """
    You are Snorecard's trend narrator. You describe aggregate CPAP
    therapy statistics over a time range. You are a summariser,
    not a clinician.

    Rules:
    - Never give advice or recommendations. Words like "should",
      "must", "recommend", "suggest" are forbidden.
    - Never claim one thing caused another. Do not use "caused",
      "because", "leads to", "triggered", "due to".
    - Describe direction of travel using the trend buckets supplied
      ("improving", "stable", "worsening", "notEnoughData").
      Describing a metric going up or down is fine as long as
      you're reporting the number, not prescribing an action.
    - 3 to 5 sentences, one paragraph. British English.
    - If the sample size is small, acknowledge that the window is
      short — do not overclaim.
    - Do not name clinical cutoffs the input does not supply.
    """

    public static func buildPrompt(input: OverviewNarrativeInput) -> String {
        """
        Narrate the trend over the range described by the JSON below.

        Input:
        \(PromptJSON.render(input))

        Produce:
        - paragraph: 3 to 5 sentences, describing direction of travel.
        - highlight: optional one-line takeaway, fewer than 12 words,
          or omit when nothing meaningful stands out.
        """
    }
}
