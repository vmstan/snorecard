import SwiftUI
import Charts
import SnorecardKit

/// Full-width hero card for the day's apnea / hypopnea breakdown.
///
/// Shows the AHI number and a horizontal stacked bar of OAI / CAI / HI
/// proportions, with the by-hour events chart below when available.
struct EventDonutView: View {
    let stats: DailyStatistics

    private var hasData: Bool {
        stats.obstructiveApneaIndex
            + stats.centralApneaIndex
            + stats.hypopneaIndex > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(String(format: "%.1f", stats.ahi))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                Text("APNEA HYPOPNEA INDEX")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            stackedBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fully custom stacked bar — replaces a SwiftUI Chart so we
    /// can clip the outer rounded corners without fighting the
    /// chart's internal padding. Each segment takes a width
    /// proportional to its share of the total, with the segment
    /// label overlaid when there's enough room.
    @ViewBuilder
    private var stackedBar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if hasData {
                    segment(
                        "OA",
                        value: stats.obstructiveApneaIndex,
                        color: .eventObstructive,
                        availableWidth: geo.size.width
                    )
                    segment(
                        "H",
                        value: stats.hypopneaIndex,
                        color: .eventHypopnea,
                        availableWidth: geo.size.width
                    )
                    segment(
                        "CA",
                        value: stats.centralApneaIndex,
                        color: .eventCentral,
                        availableWidth: geo.size.width
                    )
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .overlay {
                            Text("No events")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                }
            }
        }
        .frame(height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// One coloured segment of the stacked bar. Width is computed
    /// from the segment's share of the day's total events; the
    /// caller supplies the bar's full width via the GeometryReader
    /// so the segments add up to the bar's actual size.
    @ViewBuilder
    private func segment(
        _ shortName: String,
        value: Double,
        color: Color,
        availableWidth: CGFloat
    ) -> some View {
        let total = stats.obstructiveApneaIndex
            + stats.centralApneaIndex
            + stats.hypopneaIndex
        let share = total > 0 ? value / total : 0
        let width = max(0, availableWidth * CGFloat(share))
        Rectangle()
            .fill(color)
            .frame(width: width)
            .overlay {
                if shouldLabel(value) {
                    Text(String(format: "%@ %.1f", shortName, value))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
    }

    /// Only label segments that take up at least ~8 % of the bar so the
    /// text doesn't overflow its slice.
    private func shouldLabel(_ value: Double) -> Bool {
        let total = stats.obstructiveApneaIndex
            + stats.centralApneaIndex
            + stats.hypopneaIndex
        guard total > 0 else { return false }
        return value / total > 0.08
    }
}
