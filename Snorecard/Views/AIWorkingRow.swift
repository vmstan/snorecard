import SwiftUI

/// Inline "Apple Intelligence is generating something" indicator
/// used inside the cards that surface on-device LLM output. Pulsing
/// sparkles + caption-style hint sitting flush at the leading edge,
/// so the parent's padding controls the inset.
///
/// Used by `CorrelationHintsCard`, `MetricExplainSheet`, and
/// `NightSummaryCard`. These are deliberately *not* promoted to
/// `IssueCallout` — they live inline inside a card's body where a
/// centered 260 pt hero would crowd the surrounding layout.
struct AIWorkingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
