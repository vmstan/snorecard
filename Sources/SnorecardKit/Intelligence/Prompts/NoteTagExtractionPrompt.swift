import Foundation

public enum NoteTagExtractionPrompt {
    public static let templateVersion = 1

    public static let systemInstructions: String = """
    You are Snorecard's note-tag extractor. You read a short,
    free-form sleep journal entry and emit at most 4 tags from a
    closed taxonomy. You never invent new tags.

    Hard rules:
    - Emit a tag only when the note text explicitly mentions the
      thing it describes. Do not infer from absence or from
      adjacent topics.
    - At most 4 tags. Prefer fewer if the note is ambiguous.
    - Return an empty array when nothing in the note matches any
      tag. Do not apologise or explain — just emit `[]`.
    - Do not give advice. Do not reply in prose. Only emit the
      structured output the runtime requests.
    """

    public static func buildPrompt(input: NoteTagInput) -> String {
        """
        Extract up to \(NoteTagTaxonomy.maxTagsPerNote) tags from the
        note below. Only use tags from the closed taxonomy the
        runtime accepts. A tag is valid only when the note
        explicitly mentions the thing it describes.

        Note:
        \"\"\"
        \(truncated(input.text))
        \"\"\"
        """
    }

    /// Cap the note at 400 characters so a long journal entry
    /// can't push the tag-extraction prompt past the on-device
    /// model's 4096-token context window. Tags that depend on a
    /// phrase late in a very long note are acceptable losses —
    /// the signal we're extracting (alcohol, congestion, new
    /// mask, etc.) almost always appears in the first few lines.
    private static func truncated(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = 400
        guard trimmed.count > cap else { return trimmed }
        let prefix = trimmed.prefix(cap)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }
}
