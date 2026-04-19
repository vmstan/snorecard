import SwiftUI
import SnorecardKit

/// Paragraph-long on-device narrative of direction-of-travel for
/// the current Overview range. Sits between the summary cards and
/// the AHI chart. Re-runs whenever the range inputs change; cache
/// hits are instant.
struct TrendNarrativeCard: View {
    let stats: [DailyStatistics]
    let rangeStart: Date
    let rangeEnd: Date
    @Environment(Library.self) private var library
    @State private var narrative: OverviewNarrativeOutput?
    @State private var isLoading = false
    @State private var failed = false

    var body: some View {
        if !failed {
            innerView
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .task(id: reloadKey) {
                    await load()
                }
        }
    }

    private var reloadKey: String {
        let ahiDigest = stats
            .map { String(format: "%.2f", $0.ahi) }
            .joined(separator: ",")
        return "\(rangeStart.timeIntervalSince1970)-\(rangeEnd.timeIntervalSince1970)-\(stats.count)-\(ahiDigest.hashValue)"
    }

    @ViewBuilder
    private var innerView: some View {
        if let narrative {
            loadedContent(narrative)
        } else {
            placeholderContent
        }
    }

    @ViewBuilder
    private func loadedContent(_ narrative: OverviewNarrativeOutput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Trend summary")
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
            if let highlight = narrative.highlight, !highlight.isEmpty {
                Text(highlight)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(narrative.paragraph)
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
            Text("Writing a trend summary…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        narrative = nil
        failed = false
        isLoading = true
        defer { isLoading = false }
        let result = await library.overviewNarrative(
            stats: stats,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
        if result == nil {
            failed = true
        } else {
            narrative = result
        }
    }
}
