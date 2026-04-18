import SwiftUI
import SnorecardKit

/// Surfaces observational hints from the intersection of note tags
/// and computed stats. The correlation math runs in pure Swift
/// (`TagCorrelator`); the LLM only narrates the result. Hidden
/// entirely when the range doesn't clear the minimum-sample
/// thresholds, when no tagged nights produce a strong enough
/// delta, or when Apple Intelligence is unavailable.
struct CorrelationHintsCard: View {
    let stats: [DailyStatistics]
    let rangeStart: Date
    let rangeEnd: Date
    @Environment(Library.self) private var library
    @State private var bundle: Library.CorrelationBundle?
    @State private var isLoading = false
    @State private var hidden = false

    var body: some View {
        Group {
            if hidden {
                EmptyView()
            } else if let bundle {
                content(bundle)
            } else if isLoading {
                placeholder
            } else {
                EmptyView()
            }
        }
        .task(id: reloadKey) {
            await load()
        }
    }

    private var reloadKey: String {
        "\(rangeStart.timeIntervalSince1970)-\(rangeEnd.timeIntervalSince1970)-\(stats.count)"
    }

    @ViewBuilder
    private func content(_ bundle: Library.CorrelationBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Patterns in your notes")
                    .font(.headline)
                Spacer()
                Text("On-device")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Text(bundle.narration.intro)
                .font(.callout)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bundle.narration.bullets.prefix(3).enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(bullet)
                            .font(.callout)
                    }
                }
            }
            Text("Observations only — not medical advice.")
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
            Text("Looking for patterns…")
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
        bundle = nil
        hidden = false
        isLoading = true
        defer { isLoading = false }
        let result = await library.correlationHints(
            stats: stats,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
        if let result {
            bundle = result
        } else {
            hidden = true
        }
    }
}
