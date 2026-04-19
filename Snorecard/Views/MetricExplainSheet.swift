import SwiftUI
import SnorecardKit

/// Sheet opened when the user taps a stat card on `DayDetailView`.
/// Displays an on-device explanation of the metric, tailored to
/// the user's current value. Hidden affordance when Apple
/// Intelligence is unavailable — the taps that would open this
/// sheet are never wired up on unsupported devices.
struct MetricExplainSheet: View {
    let day: ResMedDay
    let metric: ExplainableMetric
    let displayLabel: String
    let displayValue: String
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var explanation: MetricExplainOutput?
    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerRow
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Every dynamic state (loading, loaded, failed)
                    // is wrapped in the same leading-aligned max-
                    // width frame so the text column width doesn't
                    // shift when content arrives.
                    Group {
                        if let explanation {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(explanation.whatItMeans)
                                    .font(.callout)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                                Text(explanation.howYoursLooks)
                                    .font(.callout)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else if failed {
                            Text("An explanation isn't available right now.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            placeholder
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 8)
                    Text("Summary only — not medical advice.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(displayLabel)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CloseSheetButton { dismiss() }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        .task(id: metric) {
            await load()
        }
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayValue)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text("Your value for this night")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var placeholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            Text("Preparing an explanation…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        explanation = nil
        failed = false
        isLoading = true
        defer { isLoading = false }
        let trailing = trailingStats()
        let result = await library.explainMetric(
            metric,
            for: day,
            trailing: trailing
        )
        if Task.isCancelled { return }
        if result == nil {
            failed = true
        } else {
            explanation = result
        }
    }

    private func trailingStats() -> [DailyStatistics] {
        guard let card = library.card else { return [] }
        let calendar = Calendar.current
        guard let windowStart = calendar.date(byAdding: .day, value: -14, to: day.date)
        else { return [] }
        return card.days
            .compactMap(\.stats)
            .filter { $0.hasUsage && $0.date >= windowStart && $0.date < day.date }
    }
}
