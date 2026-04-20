import SwiftUI
import SnorecardKit

/// One-paragraph on-device narrative sitting above the event donut
/// on `DayDetailView`. Hidden entirely when Apple Intelligence is
/// unavailable, when the night has no recorded usage, or when
/// generation fails the guardrail check.
struct NightSummaryCard: View {
    let day: ResMedDay
    @Environment(Library.self) private var library
    @State private var summary: NightSummaryOutput?
    @State private var isLoading = false
    @State private var failed = false

    var body: some View {
        // `failed` hides the card entirely (no placeholder, no
        // error surface) per the product decision for AI-backed
        // surfaces. Every other state renders through the same
        // shared chrome (frame / padding / background) so the
        // card doesn't re-measure when switching between
        // placeholder and final content — keeping the width and
        // leading edge locked across the load lifecycle.
        if !failed {
            innerView
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .task(id: day.id) {
                    await load()
                }
        }
    }

    @ViewBuilder
    private var innerView: some View {
        if let summary {
            loadedContent(summary)
        } else {
            placeholderContent
        }
    }

    @ViewBuilder
    private func loadedContent(_ summary: NightSummaryOutput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                // Fixed title — the model now only generates the
                // paragraph. A stable card header reads more
                // calmly than a freshly-invented 3-word line on
                // every regeneration.
                Text("Sleep Analysis")
                    .font(.headline)
                Spacer()
                Text("On-device")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(summary.paragraph)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Summary only — not medical advice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var placeholderContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            Text("Writing a summary…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        summary = nil
        failed = false
        isLoading = true
        defer { isLoading = false }
        let result = await library.nightSummary(for: day)
        // Intentionally no `Task.isCancelled` bail here. If the
        // task gets cancelled mid-flight the view typically also
        // unmounts (so the state write is a no-op), and if it
        // doesn't — e.g. Foundation Models cancels a session
        // because a previous one hasn't finished cleanup —
        // setting `failed` hides the card cleanly instead of
        // leaving the placeholder visible forever. A fresh view
        // instance on re-navigation will try again.
        if result == nil {
            failed = true
        } else {
            summary = result
        }
    }
}
