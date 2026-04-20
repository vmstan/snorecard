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
    /// One tap's worth of "explain this card" context used
    /// internally while building the card grid. Only the bits
    /// needed to populate an `ExplainRequest` live here — the
    /// sheet/inspector itself is owned by `ContentView` via
    /// `library.pendingExplain`.
    struct OverviewExplainContext {
        let metric: ExplainableMetric
        let displayValue: String
        let averageValue: Double
    }

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
                        if library.intelligence.isReady {
                            CorrelationHintsCard(
                                stats: stats,
                                rangeStart: rangeStart,
                                rangeEnd: rangeEnd
                            )
                        }
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
        #if os(macOS)
        // Matches the per-night Sleep Journal button in
        // `DayDetailView`'s toolbar — same glyph, same label —
        // but this one is scoped to the whole device. Routes
        // through the shared `.snorecardOpenDeviceNotes`
        // notification so `ContentView` owns the inspector
        // state and the third column stays the one surface
        // hosting accessory views.
        .toolbar {
            if library.intelligence.isReady {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        library.pendingOverviewAnalysis = OverviewAnalysisRequest(
                            stats: stats,
                            rangeStart: rangeStart,
                            rangeEnd: rangeEnd
                        )
                    } label: {
                        Label("Sleep Analysis", systemImage: "sparkles")
                    }
                    .disabled(stats.isEmpty)
                    .help("On-device AI summary of this range")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NotificationCenter.default.post(
                        name: .snorecardOpenDeviceNotes,
                        object: nil
                    )
                } label: {
                    Label("Sleep Journal", systemImage: "note.text")
                }
                .help("Add or edit overall notes for this device")
            }
        }
        #endif
        // iOS + macOS: listen for Sleep Analysis requests posted
        // from the shared Options menu / File menu. macOS routes
        // through `library.pendingOverviewAnalysis`; iOS does the
        // same, and the sheet binding at ContentView picks it up.
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenOverviewAnalysis)) { _ in
            guard !stats.isEmpty else { return }
            library.pendingOverviewAnalysis = OverviewAnalysisRequest(
                stats: stats,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd
            )
        }
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
        // Per-event-class indices averaged across the same set of
        // nights AHI is computed over. Surfaced as a subtitle on
        // the Avg AHI card so the user can see which event type
        // is driving the overall index.
        let avgOAI = days == 0 ? 0 : stats.reduce(0) { $0 + $1.obstructiveApneaIndex } / Double(days)
        let avgHI = days == 0 ? 0 : stats.reduce(0) { $0 + $1.hypopneaIndex } / Double(days)
        let avgCAI = days == 0 ? 0 : stats.reduce(0) { $0 + $1.centralApneaIndex } / Double(days)
        let avgSessions = averageSessionsPerNight()
        let avgGI = averaging(\.glasgowIndex)
        let avgApnea = averaging(\.timeInApneaSeconds)
        // Source from `epap95` (target EPAP) so the Overview card
        // aligns with the EPAP card on the Daily view. The raw
        // `pressure95` field (measured mask pressure) still backs
        // the pressureChart trend below, where the clinical framing
        // is "what the mask actually held".
        let avgEPAP = averaging(\.epap95)
        let avgIPAP = averaging(\.ipap95)
        let avgFlow = averaging(\.flowLimit95)
        let avgLeak = averaging(\.leak95LPerMin)
        let avgLargeLeakPct = avgLargeLeakPercent()
        let avgTidal = averaging(\.tidalVolume50)
        let avgSnore = averaging(\.snore95)

        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            card(
                "Days with data",
                value: "\(days)",
                subtitle: dateRangeLabel,
                explain: OverviewExplainContext(
                    metric: .daysWithData,
                    displayValue: "\(days) night\(days == 1 ? "" : "s")",
                    averageValue: Double(days)
                )
            )
            let compliancePct = (compliance * 100).rounded()
            card(
                "Compliance",
                value: "\(Int(compliancePct))%",
                subtitle: "\(compliantDays) of \(days) days ≥ 4h",
                tint: compliance >= 0.7 ? .severityGood : .severityMedium,
                explain: OverviewExplainContext(
                    metric: .compliance,
                    displayValue: "\(Int(compliancePct))% of nights ≥ 4h",
                    averageValue: compliancePct
                )
            )
            card(
                "Avg usage / night",
                value: formatMinutes(avgUsageMinutes),
                tint: usageColor(avgUsageMinutes / 60),
                explain: OverviewExplainContext(
                    metric: .usage,
                    displayValue: formatMinutes(avgUsageMinutes),
                    averageValue: avgUsageMinutes / 60
                )
            )
            if let avgSessions {
                card(
                    "Avg sessions / night",
                    value: String(format: "%.1f", avgSessions),
                    explain: OverviewExplainContext(
                        metric: .sessionsPerNight,
                        displayValue: String(format: "%.1f per night", avgSessions),
                        averageValue: avgSessions
                    )
                )
            }
            card(
                "Avg AHI",
                value: String(format: "%.1f", avgAHI),
                subtitle: String(
                    format: "OA %.1f · H %.1f · CA %.1f",
                    avgOAI, avgHI, avgCAI
                ),
                tint: ahiColor(avgAHI),
                explain: OverviewExplainContext(
                    metric: .ahi,
                    displayValue: String(format: "%.1f events/hr", avgAHI),
                    averageValue: avgAHI
                )
            )
            if let apnea = avgApnea {
                let pct = avgApneaPercent() ?? 0
                card(
                    "Avg time in apnea",
                    value: formatDurationShort(apnea),
                    subtitle: "per night",
                    tint: apneaColor(pct),
                    explain: OverviewExplainContext(
                        metric: .timeInApnea,
                        displayValue: String(format: "%.2f%% of usage", pct),
                        averageValue: pct
                    )
                )
            }
            if let epap = avgEPAP {
                card(
                    "Avg EPAP (95%)",
                    value: String(format: "%.1f cmH₂O", epap),
                    explain: OverviewExplainContext(
                        metric: .epap95,
                        displayValue: String(format: "%.1f cmH₂O", epap),
                        averageValue: epap
                    )
                )
            }
            // Separate Avg IPAP card, shown only when the average
            // IPAP sits meaningfully above EPAP — i.e. the range
            // includes nights with bilevel / EPR-style therapy.
            // On plain CPAP the two averages match and a second
            // card would just echo the first.
            if let epap = avgEPAP,
               let ipap = avgIPAP,
               ipap > epap + 0.05
            {
                card(
                    "Avg IPAP (95%)",
                    value: String(format: "%.1f cmH₂O", ipap),
                    explain: OverviewExplainContext(
                        metric: .ipap95,
                        displayValue: String(format: "%.1f cmH₂O", ipap),
                        averageValue: ipap
                    )
                )
            }
            if let flow = avgFlow {
                card(
                    "Avg flow limit 95th",
                    value: String(format: "%.2f", flow),
                    tint: flowLimitColor(flow),
                    explain: OverviewExplainContext(
                        metric: .flowLimit,
                        displayValue: String(format: "%.2f", flow),
                        averageValue: flow
                    )
                )
            }
            if let gi = avgGI {
                card(
                    "Avg Glasgow Index",
                    value: String(format: "%.2f", gi),
                    tint: glasgowColor(gi),
                    explain: OverviewExplainContext(
                        metric: .glasgowIndex,
                        displayValue: String(format: "%.2f", gi),
                        averageValue: gi
                    )
                )
            }
            if let tidal = avgTidal {
                let mL = tidal * 1000
                card(
                    "Avg tidal volume",
                    value: String(format: "%.0f mL", mL),
                    tint: tidalVolumeColor(mL),
                    explain: OverviewExplainContext(
                        metric: .tidalVolume,
                        displayValue: String(format: "%.0f mL", mL),
                        averageValue: mL
                    )
                )
            }
            if let snore = avgSnore {
                card(
                    "Avg snore 95th",
                    value: String(format: "%.1f", snore),
                    tint: snoreColor(snore),
                    explain: OverviewExplainContext(
                        metric: .snore95,
                        displayValue: String(format: "%.1f", snore),
                        averageValue: snore
                    )
                )
            }
            if let leak = avgLeak {
                card(
                    "Avg leak 95th",
                    value: String(format: "%.0f L/min", leak),
                    tint: leakColor(leak),
                    explain: OverviewExplainContext(
                        metric: .leak95,
                        displayValue: String(format: "%.0f L/min", leak),
                        averageValue: leak
                    )
                )
            }
            if let largeLeak = avgLargeLeakPct {
                card(
                    "Avg large leak",
                    value: String(format: "%.0f%%", largeLeak),
                    subtitle: "of usage",
                    tint: largeLeak < 0.5 ? .severityGood : .severityHigh,
                    explain: OverviewExplainContext(
                        metric: .largeLeak,
                        displayValue: String(format: "%.1f%% of usage", largeLeak),
                        averageValue: largeLeak
                    )
                )
            }
        }
    }

    /// Thin wrapper around `StatCard` so the Overview grid shares the
    /// same visual treatment and vertical alignment as the daily view.
    /// Passing an `explain` context wires the card up as a button
    /// that opens `MetricExplainSheet` with the range-scoped loader.
    private func card(
        _ label: String,
        value: String,
        subtitle: String? = nil,
        tint: Color = .primary,
        explain: OverviewExplainContext? = nil
    ) -> some View {
        StatCard(
            label: label,
            value: value,
            subtitle: subtitle,
            tint: tint,
            onTap: explainTap(explain)
        )
    }

    /// Toggle behaviour: tapping the card that is already
    /// showing dismisses the inspector (matching how other
    /// inspector panes already toggle on re-tap).
    private func explainTap(_ ctx: OverviewExplainContext?) -> (() -> Void)? {
        guard let ctx, library.intelligence.isReady else { return nil }
        let capturedStart = rangeStart
        let capturedEnd = rangeEnd
        let sampleSize = stats.count
        return {
            let request = ExplainRequest(
                metric: ctx.metric,
                displayLabel: Self.displayLabel(for: ctx.metric),
                displayValue: ctx.displayValue,
                valueCaption: "Your average for this range",
                source: .overview(
                    averageValue: ctx.averageValue,
                    rangeStart: capturedStart,
                    rangeEnd: capturedEnd,
                    sampleSize: sampleSize
                )
            )
            if library.pendingExplain == request {
                library.pendingExplain = nil
            } else {
                library.pendingExplain = request
            }
        }
    }

    /// Short navigation-bar title for the explain sheet. Matches
    /// the on-card wording rather than the longer clinical label
    /// that goes into the prompt.
    static func displayLabel(for metric: ExplainableMetric) -> String {
        switch metric {
        case .ahi:              return "Avg AHI"
        case .glasgowIndex:     return "Avg Glasgow Index"
        case .epap95:           return "Avg EPAP (95%)"
        case .ipap95:           return "Avg IPAP (95%)"
        case .leak95:           return "Avg Leak (95%)"
        case .largeLeak:        return "Avg Large Leak"
        case .tidalVolume:      return "Avg Tidal Volume"
        case .snore95:          return "Avg Snore (95%)"
        case .usage:            return "Avg Usage"
        case .timeInApnea:      return "Avg Time in Apnea"
        case .flowLimit:        return "Avg Flow Limit (95%)"
        case .compliance:       return "Compliance"
        case .daysWithData:     return "Days with Data"
        case .sessionsPerNight: return "Avg Sessions / Night"
        }
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

    /// Card chrome matching `HourlyChartCard` / `AHIHourlyChart` on
    /// the Daily view — small uppercase caption title, tertiary
    /// subtitle, and an inset-plate background so the trend charts
    /// read as part of the same visual set as the day view's
    /// hourly breakdowns.
    @ViewBuilder
    private func chartSection<C: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        .padding(14)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
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

    /// Glasgow Index palette — neutral under 2, amber 2–3, red ≥ 3.
    private func glasgowColor(_ value: Double) -> Color {
        switch value {
        case ..<2.0: .severityGood
        case ..<3.0: .severityLow
        default: .severityHigh
        }
    }

    /// Usage palette — red under 4h (non-compliant), amber 4–7h (short),
    /// green 7–9h (target), amber 9–10h (long), red ≥ 10h (over-use).
    private func usageColor(_ hours: Double) -> Color {
        switch hours {
        case ..<4: .severityHigh
        case ..<7: .severityLow
        case ..<9: .severityGood
        case ..<10: .severityLow
        default: .severityHigh
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
    /// Snore palette — same boundaries as the Daily view so the
    /// average card tints the same way the per-night card would.
    private func snoreColor(_ index: Double) -> Color {
        switch index {
        case ..<1: .severityGood
        case ..<3: .severityLow
        default: .severityHigh
        }
    }

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
