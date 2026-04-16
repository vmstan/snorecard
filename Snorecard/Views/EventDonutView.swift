import SwiftUI
import Charts
import SnorecardKit

/// Full-width hero card for the day's apnea / hypopnea breakdown.
///
/// Shows the AHI number and a horizontal stacked bar of OAI / CAI / HI
/// proportions, with the by-hour events chart below when available.
struct EventDonutView: View {
    let stats: DailyStatistics
    var hourlyEvents: [TimedEvent] = []
    var hourlyDayStart: Date? = nil

    private var hasData: Bool {
        stats.obstructiveApneaIndex
            + stats.centralApneaIndex
            + stats.hypopneaIndex > 0
    }

    private var hasHourlyChart: Bool {
        hourlyDayStart != nil && !hourlyEvents.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(String(format: "%.2f", stats.ahi))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                Text("AHI")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            stackedBar

            if hasHourlyChart, let hourlyDayStart {
                AHIHourlyChart(events: hourlyEvents, dayStart: hourlyDayStart)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var stackedBar: some View {
        Chart {
            if hasData {
                barSegment("Obstructive", value: stats.obstructiveApneaIndex, color: .eventObstructive)
                barSegment("Hypopnea", value: stats.hypopneaIndex, color: .eventHypopnea)
                barSegment("Central", value: stats.centralApneaIndex, color: .eventCentral)
            } else {
                BarMark(
                    x: .value("Index", 1),
                    y: .value("", "ahi")
                )
                .foregroundStyle(Color.secondary.opacity(0.18))
                .annotation(position: .overlay) {
                    Text("No events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartForegroundStyleScale([
            "Obstructive": Color.eventObstructive,
            "Central": Color.eventCentral,
            "Hypopnea": Color.eventHypopnea
        ])
        .frame(height: 36)
    }

    private func barSegment(_ name: String, value: Double, color: Color) -> some ChartContent {
        BarMark(
            x: .value("Index", value),
            y: .value("", "ahi")
        )
        .foregroundStyle(by: .value("Type", name))
        .annotation(position: .overlay) {
            if shouldLabel(value) {
                Text(String(format: "%@ %.1f", shortLabel(for: name), value))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func shortLabel(for name: String) -> String {
        switch name {
        case "Obstructive": "OA"
        case "Central": "CA"
        case "Hypopnea": "H"
        default: name
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
