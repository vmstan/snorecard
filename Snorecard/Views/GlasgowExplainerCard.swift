import SwiftUI

/// Static "How it works" panel for the Glasgow Index, mirroring
/// `NEDExplainerCard`'s chrome. The Glasgow algorithm scores each
/// inspiration against nine sub-indices and sums them into the
/// night's overall Index, so this card enumerates all nine in the
/// same order the algorithm scores them. Keeping the panel static
/// means the wording — and the attribution at the bottom — stay
/// verbatim regardless of whether the on-device model produced a
/// per-night narrative. Sub-index labels match the
/// `DayDetailView.glasgowTopContributor` wording so the dominant
/// contributor shown on the StatCard subtitle resolves cleanly
/// back to a row here.
struct GlasgowExplainerCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.tint)
                Text("How Glasgow Index works")
                    .font(.headline)
            }
            Text("The Glasgow Index scores every breath against nine characteristics of inspiration shape and rhythm. Each sub-score is the fraction of breaths that triggered the criterion (0 to 1); the nine sub-scores sum into the night's overall Index — lower is better.")
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                row(
                    "01",
                    title: "Skewed",
                    body: "The breath is asymmetric — peak inspiratory flow lands well before or after the inspiration's midpoint instead of near the middle."
                )
                row(
                    "02",
                    title: "Top-heavy",
                    body: "Inspirations that spend a long time within 10% of peak flow — a flow-limited plateau where the breath sits at the top instead of rounding through it."
                )
                row(
                    "03",
                    title: "Flat-top",
                    body: "Very low flow variance across the middle of the inspiration — the breath rises, sits at the peak, and falls back, with almost no curvature on top."
                )
                row(
                    "04",
                    title: "Spiky",
                    body: "The opposite shape from flat-top — the breath spends barely any time near peak flow, suggesting a brief inhalation rather than a sustained one."
                )
                row(
                    "05",
                    title: "Multi-peak",
                    body: "Bimodal inspiration — flow dips below the running peak and rises again, often tied to upper-airway resistance."
                )
                row(
                    "06",
                    title: "No pause",
                    body: "The next breath starts almost immediately after the previous one ends, with no rest at the end of expiration."
                )
                row(
                    "07",
                    title: "Fast rate",
                    body: "Inspiration rate above roughly 20 per minute — quicker than the typical adult breathing rhythm during sleep."
                )
                row(
                    "08",
                    title: "Missed exhale",
                    body: "Two inspirations stitched together without a clean exhalation between them — the breathing cycle didn't return to baseline."
                )
                row(
                    "09",
                    title: "Variable amplitude",
                    body: "Large breath-to-breath variation in peak inspiratory flow — consecutive breaths land at noticeably different sizes."
                )
            }
            Text("Algorithm by DaveSkvn (github.com/DaveSkvn/GlasgowIndex, GPL-3.0). Informational only — not a clinical diagnostic.")
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
