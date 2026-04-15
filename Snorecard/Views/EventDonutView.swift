import SwiftUI
import Charts
import SnorecardKit

/// Full-width hero card for the day's apnea / hypopnea breakdown.
///
/// Shows a large donut chart, the total event count centred inside it,
/// and a legend listing each event type with its per-hour index.
struct EventDonutView: View {
    let stats: DailyStatistics
    var hourlyEvents: [TimedEvent] = []
    var hourlyDayStart: Date? = nil

    private var hasData: Bool {
        stats.obstructiveApneaIndex
            + stats.centralApneaIndex
            + stats.hypopneaIndex > 0
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Wide layout: donut / legend / chart all in a single row.
            wideLayout
            // Medium layout: donut + legend side by side, chart stacked below.
            mediumLayout
            // Narrow layout: donut centred at top, legend below, chart below.
            narrowLayout
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wideLayout: some View {
        HStack(alignment: .center, spacing: 24) {
            donutWithCenter(size: 192)
            legendColumn
                .fixedSize(horizontal: true, vertical: false)
            if hasHourlyChart {
                hourlyChart
                    .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 20) {
                donutWithCenter(size: 192)
                legendColumn
                Spacer(minLength: 0)
            }
            if hasHourlyChart {
                hourlyChart
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                donutWithCenter(size: 160)
                Spacer()
            }
            legendColumn
            if hasHourlyChart {
                hourlyChart
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var hasHourlyChart: Bool {
        hourlyDayStart != nil && !hourlyEvents.isEmpty
    }

    @ViewBuilder
    private var hourlyChart: some View {
        if let hourlyDayStart {
            AHIHourlyChart(events: hourlyEvents, dayStart: hourlyDayStart)
        }
    }

    private func donutWithCenter(size: CGFloat) -> some View {
        ZStack {
            donut
                .frame(width: size, height: size)
            VStack(spacing: 2) {
                Text(String(format: "%.1f", stats.ahi))
                    .font(.system(size: size * 0.27, weight: .bold, design: .rounded).monospacedDigit())
                Text("AHI")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var legendColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            legendRow(
                color: .red,
                fullLabel: "Obstructive Apnea",
                shortLabel: "OAI",
                value: stats.obstructiveApneaIndex
            )
            legendRow(
                color: .purple,
                fullLabel: "Central Apnea",
                shortLabel: "CAI",
                value: stats.centralApneaIndex
            )
            legendRow(
                color: .yellow,
                fullLabel: "Hypopnea",
                shortLabel: "HI",
                value: stats.hypopneaIndex
            )
        }
    }

    @ViewBuilder
    private var donut: some View {
        Chart {
            if hasData {
                SectorMark(
                    angle: .value("OAI", stats.obstructiveApneaIndex),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.2
                )
                .foregroundStyle(Color.red)
                .cornerRadius(3)

                SectorMark(
                    angle: .value("CAI", stats.centralApneaIndex),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.2
                )
                .foregroundStyle(Color.purple)
                .cornerRadius(3)

                SectorMark(
                    angle: .value("HI", stats.hypopneaIndex),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.2
                )
                .foregroundStyle(Color.yellow)
                .cornerRadius(3)
            } else {
                SectorMark(
                    angle: .value("None", 1),
                    innerRadius: .ratio(0.62)
                )
                .foregroundStyle(Color.secondary.opacity(0.18))
            }
        }
        .chartLegend(.hidden)
    }

    private func legendRow(
        color: Color,
        fullLabel: String,
        shortLabel: String,
        value: Double
    ) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(fullLabel)
                    .font(.subheadline.weight(.medium))
                Text("\(shortLabel) · \(String(format: "%.1f", value))/hr")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
