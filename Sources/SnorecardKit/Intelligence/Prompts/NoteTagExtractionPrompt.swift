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
        \(input.text)
        \"\"\"
        """
    }
}
