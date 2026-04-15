import SwiftUI
import Charts
import SnorecardKit

struct OverviewView: View {
    let card: ResMedSDCard

    private var stats: [DailyStatistics] {
        card.days
            .compactMap(\.stats)
            .filter(\.hasUsage)
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if stats.isEmpty {
                    ContentUnavailableView(
                        "No summary data",
                        systemImage: "chart.bar.xaxis",
                        description: Text("This SD card has no STR.edf records with recorded usage yet.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    summaryCards
                    ahiChart
                    usageChart
                    pressureChart
                    leakChart
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
    }

    // MARK: - Aggregate cards

    private var summaryCards: some View {
        let days = stats.count
        let totalUsage = stats.reduce(0) { $0 + $1.usageMinutes }
        let avgUsageMinutes = days == 0 ? 0 : totalUsage / Double(days)
        let compliantDays = stats.filter { $0.usageHours >= 4 }.count
        let compliance = days == 0 ? 0 : Double(compliantDays) / Double(days)
        let avgAHI = days == 0 ? 0 : stats.reduce(0) { $0 + $1.ahi } / Double(days)
        let avgP95 = averaging(\.pressure95)
        let avgLeak = averaging(\.leak95LPerMin)

        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            card("Days with data", value: "\(days)", subtitle: dateRangeLabel)
            card(
                "Compliance",
                value: "\(Int((compliance * 100).rounded()))%",
                subtitle: "\(compliantDays) of \(days) days ≥ 4h",
                tint: compliance >= 0.7 ? .green : .orange
            )
            card("Avg usage / night", value: formatMinutes(avgUsageMinutes))
            card(
                "Avg AHI",
                value: String(format: "%.1f", avgAHI),
                tint: ahiColor(avgAHI)
            )
            if let p95 = avgP95 {
                card("Avg pressure 95th", value: String(format: "%.1f cmH₂O", p95))
            }
            if let leak = avgLeak {
                card(
                    "Avg leak 95th",
                    value: String(format: "%.0f L/min", leak),
                    tint: leak > 24 ? .orange : .primary
                )
            }
        }
    }

    private func card(
        _ label: String,
        value: String,
        subtitle: String? = nil,
        tint: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Charts

    private var ahiChart: some View {
        chartSection(title: "AHI", subtitle: "events per hour") {
            Chart(stats, id: \.date) { stat in
                BarMark(
                    x: .value("Day", stat.date, unit: .day),
                    y: .value("AHI", stat.ahi)
                )
                .foregroundStyle(ahiColor(stat.ahi))
            }
            .chartYScale(domain: 0 ... max(5, (stats.map(\.ahi).max() ?? 0) * 1.2))
            .chartYAxis {
                AxisMarks(position: .leading)
                AxisMarks(values: [5]) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundStyle(.secondary)
                    AxisValueLabel("5")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var usageChart: some View {
        chartSection(title: "Usage", subtitle: "hours per night (dashed line: 4h compliance)") {
            Chart(stats, id: \.date) { stat in
                BarMark(
                    x: .value("Day", stat.date, unit: .day),
                    y: .value("Hours", stat.usageHours)
                )
                .foregroundStyle(stat.usageHours >= 4 ? Color.accentColor : Color.accentColor.opacity(0.4))
                RuleMark(y: .value("Compliance", 4))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            }
            .chartYScale(domain: 0 ... max(8, (stats.map(\.usageHours).max() ?? 0) * 1.15))
        }
    }

    private var pressureChart: some View {
        let hasData = stats.contains { $0.pressure95 != nil }
        return chartSection(title: "Pressure", subtitle: "median and 95th percentile (cmH₂O)") {
            if hasData {
                Chart(stats, id: \.date) { stat in
                    if let p95 = stat.pressure95 {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("P95", p95),
                            series: .value("Series", "95th")
                        )
                        .foregroundStyle(.orange)
                        .symbol(Circle())
                    }
                    if let median = stat.pressureMedian {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Median", median),
                            series: .value("Series", "Median")
                        )
                        .foregroundStyle(.blue)
                        .symbol(Circle())
                    }
                }
                .chartForegroundStyleScale([
                    "95th": .orange,
                    "Median": .blue
                ])
            } else {
                Text("No pressure data recorded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    private var leakChart: some View {
        let hasLeak = stats.contains { $0.leak95LPerMin != nil }
        return chartSection(title: "Leak", subtitle: "95th percentile (L/min) — 24 L/min threshold") {
            if hasLeak {
                Chart(stats, id: \.date) { stat in
                    if let leak = stat.leak95LPerMin {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Leak", leak)
                        )
                        .foregroundStyle(.mint)
                        .symbol(Circle())
                    }
                    RuleMark(y: .value("Threshold", 24))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }
            } else {
                Text("No leak data recorded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    @ViewBuilder
    private func chartSection<C: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
                .frame(height: 180)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
        }
    }

    // MARK: - Helpers

    private var dateRangeLabel: String {
        guard let first = stats.first?.date, let last = stats.last?.date else { return "" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return first.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    private func averaging(_ keyPath: KeyPath<DailyStatistics, Double?>) -> Double? {
        let values = stats.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60
        let m = total % 60
        return "\(h)h \(m)m"
    }

    private func ahiColor(_ ahi: Double) -> Color {
        switch ahi {
        case ..<5: .green
        case ..<15: .yellow
        case ..<30: .orange
        default: .red
        }
    }
}
