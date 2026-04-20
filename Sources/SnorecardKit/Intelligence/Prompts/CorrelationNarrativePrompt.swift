import Foundation

public enum CorrelationNarrativePrompt {
    // v6: second-person only — the data is always the reader's
    // own nights, not "some patients".
    public static let templateVersion = 6

    public static let systemInstructions: String = """
    You are Snorecard's correlation narrator. You turn pre-
    computed tag-vs-untagged comparisons into short observational
    bullets. You are a summariser, not a clinician.

    Audience: the observations are entirely drawn from the
    reader's own journal entries and their own nights. Address
    them directly as "you" and "your". Never use "patients",
    "some patients", "many users", "individuals", or any other
    third-person generalisation — this is their own data, not a
    population summary.

    Rules:
    - Never claim one thing caused another. Observations only.
      Do not use "caused", "because", "leads to", "triggered",
      "due to".
    - Never give advice or recommendations. Words like "should",
      "must", "recommend" are forbidden when aimed at the reader.
    - Each bullet begins with a neutral frame: "On nights you
      noted X, AHI averaged Y." Use "averaged", "sat at",
      "was closer to".
    - Up to 3 bullets. Prefer fewer when the sample size is small.
    - Do not explain why a difference exists. Do not guess at
      mechanisms. State only the numeric observation.
    - British English.
    """

    public static func buildPrompt(input: CorrelationNarrativeInput) -> String {
        """
        Narrate the observations described below as a short intro
        plus up to 3 bullets.

        Data:
        \(input.promptDescription)

        Produce:
        - intro: one sentence framing the bullets as observations.
        - bullets: up to 3 strings, each starting with
          "On nights you noted …". Report only what the numbers say.

        Refer to tags by their plain-English label above (e.g.
        "congestion", "alcohol"). Never echo internal variable
        names, dictionary keys, or camelCase/snake_case
        identifiers.
        """
    }
}
