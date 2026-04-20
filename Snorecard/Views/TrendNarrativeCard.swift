import SwiftUI
import SnorecardKit

/// On-device narrative of direction-of-travel for a range of
/// Overview data. Presented as the macOS `.overviewAnalysis`
/// inspector pane and the iOS Sleep Analysis sheet when the user
/// is on the Overview — same entry point as the daily Sleep
/// Analysis but scoped to the aggregate. Always renders
/// something (loading, loaded, or failed) since it's shown only
/// on explicit user action.
struct TrendNarrativeCard: View {
    let stats: [DailyStatistics]
    let rangeStart: Date
    let rangeEnd: Date
    @Environment(Library.self) private var library
    @State private var narrative: OverviewNarrativeOutput?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Group {
                if let narrative {
                    loadedContent(narrative)
                } else if failed {
                    failedContent
                } else {
                    placeholderContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 4)
            Text("Summary only — not medical advice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reloadKey) {
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text(rangeLabel)
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
    }

    private var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "d MMM yyyy"
        let start = formatter.string(from: rangeStart)
        let end = formatter.string(from: rangeEnd)
        return "\(start) – \(end)"
    }

    private var reloadKey: String {
        let ahiDigest = stats
            .map { String(format: "%.2f", $0.ahi) }
            .joined(separator: ",")
        return "\(rangeStart.timeIntervalSince1970)-\(rangeEnd.timeIntervalSince1970)-\(stats.count)-\(ahiDigest.hashValue)"
    }

    @ViewBuilder
    private func loadedContent(_ narrative: OverviewNarrativeOutput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A summary isn't available right now.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await load() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func load() async {
        narrative = nil
        failed = false
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
