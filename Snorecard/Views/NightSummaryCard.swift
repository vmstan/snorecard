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
        Group {
            if let summary {
                content(summary)
            } else if isLoading {
                placeholder
            } else if failed {
                // Generation failed or was rejected by guardrails —
                // hide the card entirely rather than surfacing an
                // error, which is the explicit product decision
                // for AI-backed surfaces on this screen.
                EmptyView()
            } else {
                placeholder
            }
        }
        .task(id: day.id) {
            await load()
        }
    }

    @ViewBuilder
    private func content(_ summary: NightSummaryOutput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text(summary.headline)
                    .font(.headline)
                Spacer()
                Text("On-device")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Text(summary.paragraph)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Text("Summary only — not medical advice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var placeholder: some View {
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
        .padding(12)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func load() async {
        summary = nil
        failed = false
        isLoading = true
        defer { isLoading = false }
        let result = await library.nightSummary(for: day)
        if result == nil {
            failed = true
        } else {
            summary = result
        }
    }
}
