import SwiftUI
import Charts
import SnorecardKit

struct OverviewView: View {
    let card: ResMedSDCard
    @Environment(Library.self) private var library
    @State private var rangeKind: RangeKind = .last14
    @State private var customStart: Date = Calendar.current
        .date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
    @State private var customEnd: Date = Calendar.current.startOfDay(for: Date())

    /// Date ranges selectable from the Overview header.
    enum RangeKind: Hashable {
        case all, last7, last14, last30, custom
    }

    /// All days with usage, ignoring the current range filter. Used by
    /// `stats` (filtered) and by the empty-state check.
    private var allStats: [DailyStatistics] {
        card.days
            .compactMap(\.stats)
            .filter(\.hasUsage)
            .sorted { $0.date < $1.date }
    }

    /// Days that fall inside the currently-selected range.
    private var stats: [DailyStatistics] {
        allStats.filter { $0.date >= rangeStart && $0.date <= rangeEnd }
    }

    private var rangeStart: Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch rangeKind {
        case .all:    return allStats.first?.date ?? today
        case .last7:  return cal.date(byAdding: .day, value: -6, to: today) ?? today
        case .last14: return cal.date(byAdding: .day, value: -13, to: today) ?? today
        case .last30: return cal.date(byAdding: .day, value: -29, to: today) ?? today
        case .custom: return cal.startOfDay(for: customStart)
        }
    }

    private var rangeEnd: Date {
        let cal = Calendar.current
        switch rangeKind {
        case .all:    return allStats.last?.date ?? cal.startOfDay(for: Date())
        case .custom: return cal.startOfDay(for: customEnd)
        default:      return cal.startOfDay(for: Date())
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if allStats.isEmpty {
                    ContentUnavailableView(
                        "No summary data",
                        systemImage: "chart.bar.xaxis",
                        description: Text("This SD card has no STR.edf records with recorded usage yet.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    rangePicker
                    if stats.isEmpty {
                        ContentUnavailableView(
                            "No data in range",
                            systemImage: "calendar",
                            description: Text("No usage recorded between \(rangeStart, format: .dateTime.month(.abbreviated).day()) and \(rangeEnd, format: .dateTime.month(.abbreviated).day()).")
                        )
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        summaryCards
                        ahiChart
                        usageChart
                        glasgowChart
                        timeInApneaChart
                        pressureChart
                        flowLimitChart
                        tidalVolumeChart
                        leakChart
                        largeLeakChart
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
        .navigationSubtitle(library.displayName(for: card))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Segmented preset picker plus optional custom date-range pickers.
    @ViewBuilder
    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $rangeKind) {
                Text("All").tag(RangeKind.all)
                Text("7 Days").tag(RangeKind.last7)
                Text("14 Days").tag(RangeKind.last14)
                Text("30 Days").tag(RangeKind.last30)
                Text("Custom").tag(RangeKind.custom)
            }
            .pickerStyle(.segmented)

            if rangeKind == .custom {
                HStack(spacing: 16) {
                    DatePicker(
                        "From",
                        selection: $customStart,
                        in: ...customEnd,
                        displayedComponents: .date
                    )
                    DatePicker(
                        "To",
                        selection: $customEnd,
                        in: customStart...Date(),
                        displayedComponents: .date
                    )
                }
                .font(.callout)
            }
        }
    }

    // MARK: - Aggregate cards

    private var summaryCards: some View {
        let days = stats.count
        let totalUsage = stats.reduce(0) { $0 + $1.usageMinutes }
        let avgUsageMinutes = days == 0 ? 0 : totalUsage / Double(days)
        let compliantDays = stats.filter { $0.usageHours >= 4 }.count
        let compliance = days == 0 ? 0 : Double(compliantDays) / Double(days)
        let avgAHI = days == 0 ? 0 : stats.reduce(0) { $0 + $1.ahi } / Double(days)
        let avgSessions = averageSessionsPerNight()
        let avgGI = averaging(\.glasgowIndex)
        let avgApnea = averaging(\.timeInApneaSeconds)
        let avgP95 = averaging(\.pressure95)
        let avgFlow = averaging(\.flowLimit95)
        let avgLeak = averaging(\.leak95LPerMin)
        let avgLargeLeakPct = avgLargeLeakPercent()
        let avgTidal = averaging(\.tidalVolume50)

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
                tint: compliance >= 0.7 ? .severityGood : .severityMedium
            )
            card(
                "Avg usage / night",
                value: formatMinutes(avgUsageMinutes),
                tint: usageColor(avgUsageMinutes / 60)
            )
            if let avgSessions {
                card(
                    "Avg sessions / night",
                    value: String(format: "%.1f", avgSessions)
                )
            }
            card(
                "Avg AHI",
                value: String(format: "%.2f", avgAHI),
                tint: ahiColor(avgAHI)
            )
            if let gi = avgGI {
                card(
                    "Avg Glasgow Index",
                    value: String(format: "%.2f", gi),
                    tint: glasgowColor(gi)
                )
            }
            if let apnea = avgApnea {
                let pct = avgApneaPercent() ?? 0
                card(
                    "Avg time in apnea",
                    value: formatDurationShort(apnea),
                    subtitle: "per night",
                    tint: apneaColor(pct)
                )
            }
            if let p95 = avgP95 {
                card("Avg pressure 95th", value: String(format: "%.1f cmH₂O", p95))
            }
            if let flow = avgFlow {
                card(
                    "Avg flow limit 95th",
                    value: String(format: "%.2f", flow),
                    tint: flowLimitColor(flow)
                )
            }
            if let tidal = avgTidal {
                let mL = tidal * 1000
                card(
                    "Avg tidal volume",
                    value: String(format: "%.0f mL", mL),
                    tint: tidalVolumeColor(mL)
                )
            }
            if let leak = avgLeak {
                card(
                    "Avg leak 95th",
                    value: String(format: "%.0f L/min", leak),
                    tint: leakColor(leak)
                )
            }
            if let largeLeak = avgLargeLeakPct {
                card(
                    "Avg large leak",
                    value: String(format: "%.0f%%", largeLeak),
                    subtitle: "of usage",
                    tint: largeLeak < 0.5 ? .severityGood : .severityHigh
                )
            }
        }
    }

    /// Thin wrapper around `StatCard` so the Overview grid shares the
    /// same visual treatment and vertical alignment as the daily view.
    private func card(
        _ label: String,
        value: String,
        subtitle: String? = nil,
        tint: Color = .primary
    ) -> some View {
        StatCard(label: label, value: value, subtitle: subtitle, tint: tint)
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
                .foregroundStyle(stat.usageHours >= 4 ? Color.chartUsageStrong : Color.chartUsageWeak)
                RuleMark(y: .value("Compliance", 4))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            }
            .chartYScale(domain: 0 ... max(8, (stats.map(\.usageHours).max() ?? 0) * 1.15))
        }
    }

    private var glasgowChart: some View {
        let has = stats.contains { $0.glasgowIndex != nil }
        return chartSection(title: "Glasgow Index", subtitle: "breath-quality score (lower is better)") {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let gi = stat.glasgowIndex {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Index", gi)
                        )
                        .foregroundStyle(Color.chartTeal)
                        .symbol(Circle())
                    }
                }
            } else {
                emptyPlaceholder("No Glasgow Index recorded.")
            }
        }
    }

    private var timeInApneaChart: some View {
        let has = stats.contains { $0.timeInApneaSeconds != nil }
        return chartSection(title: "Time in Apnea", subtitle: "minutes per night") {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let s = stat.timeInApneaSeconds {
                        BarMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Minutes", s / 60)
                        )
                        .foregroundStyle(Color.eventObstructive)
                    }
                }
            } else {
                emptyPlaceholder("No event-duration data recorded.")
            }
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
                        .foregroundStyle(Color.chartOrange)
                        .symbol(Circle())
                    }
                    if let median = stat.pressureMedian {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Median", median),
                            series: .value("Series", "Median")
                        )
                        .foregroundStyle(Color.chartBlue)
                        .symbol(Circle())
                    }
                }
                .chartForegroundStyleScale([
                    "95th": Color.chartOrange,
                    "Median": Color.chartBlue
                ])
            } else {
                emptyPlaceholder("No pressure data recorded.")
            }
        }
    }

    private var flowLimitChart: some View {
        let has = stats.contains { $0.flowLimit95 != nil }
        return chartSection(title: "Flow Limit", subtitle: "95th percentile (0–1 scale)") {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let fl = stat.flowLimit95 {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Flow Limit", fl)
                        )
                        .foregroundStyle(Color.chartPink)
                        .symbol(Circle())
                    }
                }
                .chartYScale(domain: 0...max(0.2, (stats.compactMap(\.flowLimit95).max() ?? 0) * 1.2))
            } else {
                emptyPlaceholder("No flow-limit data recorded.")
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
                        .foregroundStyle(Color.chartMint)
                        .symbol(Circle())
                    }
                    RuleMark(y: .value("Threshold", 24))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }
            } else {
                emptyPlaceholder("No leak data recorded.")
            }
        }
    }

    private var largeLeakChart: some View {
        let has = stats.contains { largeLeakPercent(for: $0) != nil }
        return chartSection(title: "Large Leak", subtitle: "percent of usage above 24 L/min") {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let pct = largeLeakPercent(for: stat) {
                        BarMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Percent", pct)
                        )
                        .foregroundStyle(pct > 5 ? Color.severityMedium : Color.severityLow)
                    }
                }
            } else {
                emptyPlaceholder("No large-leak data recorded.")
            }
        }
    }

    private var tidalVolumeChart: some View {
        let has = stats.contains { $0.tidalVolume50 != nil }
        return chartSection(title: "Tidal Volume", subtitle: "median (mL)") {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let tv = stat.tidalVolume50 {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Tidal Volume", tv * 1000)
                        )
                        .foregroundStyle(Color.chartIndigo)
                        .symbol(Circle())
                    }
                }
            } else {
                emptyPlaceholder("No tidal-volume data recorded.")
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
                    AxisMarks(values: xAxisTickDates) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.day().month(.abbreviated))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    chartTapOverlay(proxy: proxy)
                }
        }
    }

    /// Transparent tap-catcher layered over every chart — translates a
    /// click/tap X position into the nearest day in `stats` and drills
    /// the sidebar into that day's detail view. `contentShape` keeps
    /// the rectangle invisible but hit-testable.
    @ViewBuilder
    private func chartTapOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                #if os(macOS)
                .onHover { inside in
                    if inside {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                #endif
                .onTapGesture { location in
                    guard let plotFrame = proxy.plotFrame else { return }
                    let frame = geometry[plotFrame]
                    let xInPlot = location.x - frame.origin.x
                    guard xInPlot >= 0, xInPlot <= frame.width else { return }
                    if let date: Date = proxy.value(atX: xInPlot) {
                        selectDay(nearest: date)
                    }
                }
        }
    }

    /// Snap `date` to the closest day with recorded data inside the
    /// current range and navigate the sidebar there. No-op when the
    /// range is empty.
    private func selectDay(nearest date: Date) {
        guard !stats.isEmpty else { return }
        let target = Calendar.current.startOfDay(for: date)
        let closest = stats.min {
            abs($0.date.timeIntervalSince(target))
                < abs($1.date.timeIntervalSince(target))
        }
        guard let match = closest,
              let day = card.days.first(where: {
                  Calendar.current.isDate($0.date, inSameDayAs: match.date)
              })
        else { return }
        library.selection = .day(day.id)
    }

    /// Choose how many X-axis ticks to emit based on the active range
    /// so labels like "14 Apr" never overlap. 7-day windows show every
    /// day, 14-day windows show every other day, 30-day windows show
    /// weekly.
    private var xAxisTickDates: [Date] {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: rangeStart, to: rangeEnd).day ?? 0
        let stride: Int
        switch days {
        case ..<8:  stride = 1
        case ..<15: stride = 2
        case ..<22: stride = 3
        default:    stride = 5
        }
        var dates: [Date] = []
        var current = cal.startOfDay(for: rangeStart)
        let end = cal.startOfDay(for: rangeEnd)
        while current <= end {
            dates.append(current)
            guard let next = cal.date(byAdding: .day, value: stride, to: current) else { break }
            current = next
        }
        // Always include the last day in the range for context.
        if let last = dates.last, last != end {
            dates.append(end)
        }
        return dates
    }

    private func emptyPlaceholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: - Helpers

    private var dateRangeLabel: String {
        guard let first = stats.first?.date, let last = stats.last?.date else { return "" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return first.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Mean number of BRP sessions across days inside the current range
    /// that recorded usage. Mirrors the "sessions" count surfaced on
    /// the daily detail view.
    private func averageSessionsPerNight() -> Double? {
        let start = rangeStart, end = rangeEnd
        let counts = card.days
            .filter { $0.stats?.hasUsage == true }
            .filter { $0.date >= start && $0.date <= end }
            .map { $0.files(of: .breath).count }
        guard !counts.isEmpty else { return nil }
        return Double(counts.reduce(0, +)) / Double(counts.count)
    }

    private func averaging(_ keyPath: KeyPath<DailyStatistics, Double?>) -> Double? {
        let values = stats.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func largeLeakPercent(for stat: DailyStatistics) -> Double? {
        guard let seconds = stat.largeLeakSeconds, stat.usageMinutes > 0 else { return nil }
        return seconds / (stat.usageMinutes * 60) * 100
    }

    private func avgLargeLeakPercent() -> Double? {
        let values = stats.compactMap { largeLeakPercent(for: $0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60
        let m = total % 60
        return "\(h)h \(m)m"
    }

    private func formatDurationShort(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            let h = total / 3600
            let m = (total % 3600) / 60
            return "\(h)h \(m)m"
        }
        if total >= 60 {
            let m = total / 60
            let s = total % 60
            return s == 0 ? "\(m) min" : "\(m)m \(s)s"
        }
        return "\(total) sec"
    }

    private func ahiColor(_ ahi: Double) -> Color {
        switch ahi {
        case ..<2: .severityGood
        case ..<5: .severityLow
        default: .severityHigh
        }
    }

    /// Leak-severity palette — green under 5 L/min, amber 5–9, red ≥ 10.
    private func leakColor(_ leak: Double) -> Color {
        switch leak {
        case ..<5: .severityGood
        case ..<10: .severityLow
        default: .severityHigh
        }
    }

    /// Flow-limit palette — green when the 95th percentile rounds to
    /// 0.00, amber in between, red ≥ 0.10.
    private func flowLimitColor(_ value: Double) -> Color {
        switch value {
        case ..<0.005: .severityGood
        case ..<0.10: .severityLow
        default: .severityHigh
        }
    }

    /// Glasgow Index palette — green ≤ 0.2, amber in between, red ≥ 3.0.
    private func glasgowColor(_ value: Double) -> Color {
        switch value {
        case ..<0.2: .severityGood
        case ..<3.0: .severityLow
        default: .severityHigh
        }
    }

    /// Usage palette — red under 4h compliance, amber 4–7h, green ≥ 7h.
    private func usageColor(_ hours: Double) -> Color {
        switch hours {
        case ..<4: .severityHigh
        case ..<7: .severityLow
        default: .severityGood
        }
    }

    /// Time-in-apnea palette (percent of usage) — green < 1 %, amber
    /// 1–3 %, red ≥ 3 %. Tighter than the clinical AHI bands.
    private func apneaColor(_ percent: Double) -> Color {
        switch percent {
        case ..<1: .severityGood
        case ..<3: .severityLow
        default: .severityHigh
        }
    }

    /// Tidal-volume palette (median mL) — two-sided: green in the 420–
    /// 600 mL sweet spot, amber on either side of that window, red at
    /// the extremes.
    private func tidalVolumeColor(_ mL: Double) -> Color {
        switch mL {
        case ..<350: .severityHigh
        case ..<420: .severityLow
        case ...600: .severityGood
        case ...700: .severityLow
        default: .severityHigh
        }
    }

    /// Average per-night percent of usage spent in apnea, computed
    /// across days that recorded both usage and an apnea-seconds value.
    private func avgApneaPercent() -> Double? {
        let values = stats.compactMap { stat -> Double? in
            guard let seconds = stat.timeInApneaSeconds,
                  stat.usageMinutes > 0 else { return nil }
            return seconds / (stat.usageMinutes * 60) * 100
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
