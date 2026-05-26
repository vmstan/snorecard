import SwiftUI

/// Static "How it works" panel for NED Analysis. The four numbered
/// rows match the headline algorithm pieces — NED, Flatness Index,
/// M-shape detection, RERA — so a reader can map the StatCard's
/// value back to the breath-by-breath maths that produced it.
///
/// The card stays static (no AI generation) on purpose: the
/// definitions don't change night-to-night, and a fixed wording
/// keeps the disclaimer at the bottom verbatim. It appears in two
/// places — the `MetricExplainSheet` for `.reraIndex`, alongside
/// any AI explanation, and inline at the foot of `DayDetailView`
/// the first time a night exposes a non-nil RERA index.
struct NEDExplainerCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "waveform.path")
                    .foregroundStyle(.tint)
                Text("How NED Analysis works")
                    .font(.headline)
            }
            Text("NED — Negative Effort Dependence — looks at the shape of every breath you take during therapy. Four signals combine into one number.")
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                row(
                    "01",
                    title: "NED per breath",
                    body: "Compares peak inspiratory flow to flow at the midpoint of the inhalation. Higher values mean more flattening."
                )
                row(
                    "02",
                    title: "Flatness Index",
                    body: "Measures how much of each inhalation sits within 10% of peak flow. ≥ 0.85 signals a clearly flow-limited breath."
                )
                row(
                    "03",
                    title: "M-shape detection",
                    body: "Finds breaths with a characteristic mid-inspiratory dip — a fingerprint of upper-airway oscillation."
                )
                row(
                    "04",
                    title: "RERA detection",
                    body: "Runs of ≥3 breaths with steadily rising NED, ended by a recovery breath, count as one event. Reported as events per hour."
                )
            }
            Text("NED concept from Tamisier et al. RERA detection adapted from AASM clinical scoring criteria — Snorecard's interpretation, not a validated diagnostic. Informational only.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ number: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
