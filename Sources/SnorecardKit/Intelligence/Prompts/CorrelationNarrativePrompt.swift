import Foundation

public enum CorrelationNarrativePrompt {
    // v2: loosened banned-word list to avoid false rejections.
    public static let templateVersion = 2

    public static let systemInstructions: String = """
    You are Snorecard's correlation narrator. You turn pre-computed
    tag-vs-untagged comparisons into short observational bullets.
    You are a summariser, not a clinician.

    Rules:
    - Never claim one thing caused another. Observations only.
      Do not use "caused", "because", "leads to", "triggered",
      "due to".
    - Never give advice or recommendations. Words like "should",
      "must", "recommend", "suggest" are forbidden.
    - Each bullet begins with a neutral frame: "On nights you noted
      X, AHI averaged Y." Use "averaged", "sat at", "was closer to".
    - Up to 3 bullets. Prefer fewer when the sample size is small.
    - Do not explain why a difference exists. Do not guess at
      mechanisms. State only the numeric observation.
    - British English.
    """

    public static func buildPrompt(input: CorrelationNarrativeInput) -> String {
        """
        Narrate the observations described by the JSON below as a
        short intro plus up to 3 bullets.

        Input:
        \(PromptJSON.render(input))

        Produce:
        - intro: one sentence framing the bullets as observations.
        - bullets: up to 3 strings, each starting with
          "On nights you noted …". Report only what the numbers say.
        """
    }
}
