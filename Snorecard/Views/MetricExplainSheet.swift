import SwiftUI
import SnorecardKit

/// Sheet opened when the user taps a stat card. Day-detail and
/// Overview cards both present this sheet — the difference is
/// which library helper produces the explanation, which the
/// caller injects via `loader`. The sheet itself stays
/// data-source agnostic; it just shows the result.
///
/// Hidden affordance when Apple Intelligence is unavailable —
/// the taps that would open the sheet are never wired up on
/// unsupported devices.
struct MetricExplainSheet: View {
    let metric: ExplainableMetric
    let displayLabel: String
    let displayValue: String
    /// Short caption under the headline value. "Your value for
    /// this night" on the day view, "Your average for this
    /// range" on the Overview.
    let valueCaption: String
    /// Async loader supplied by the caller so the sheet doesn't
    /// need to know whether the explanation is per-day or
    /// per-range. Returns `nil` on failure (unavailable /
    /// guardrail / decoding error) which flips the sheet into
    /// its "An explanation isn't available right now." state.
    let loader: () async -> MetricExplainOutput?

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
            Text(valueCaption)
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
        let result = await loader()
        if result == nil {
            failed = true
        } else {
            explanation = result
        }
    }
}
