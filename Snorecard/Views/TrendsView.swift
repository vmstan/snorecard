import SwiftUI
import Charts
import SnorecardKit

/// Y-axis label content shared by every Trends chart. Right-aligns
/// the rendered number in a fixed-width frame so the leading edge
/// of every chart's plot area lines up across the column — without
/// it, each chart's y-axis sizes to its own content and the X-axis
/// date labels drift horizontally between rows.
@ViewBuilder
fileprivate func trendsYAxisLabel(for value: AxisValue) -> some View {
    if let v = value.as(Double.self) {
        Text(v.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)))
            .font(.caption2.monospacedDigit())
            .frame(width: 32, alignment: .trailing)
    }
}

struct TrendsView: View {
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
    struct TrendsExplainContext {
        let metric: ExplainableMetric
        let displayValue: String
        let averageValue: Double
    }

    /// Date ranges selectable from the Trends header.
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

    /// Apple Watch sleep summaries that fall inside the currently-
    /// selected range, oldest first. Pulled from the coordinator's
    /// in-memory map so the view doesn't re-query HealthKit when the
    /// range changes.
    private var sleepSummariesInRange: [NightlySleepSummary] {
        library.healthSleep.summaryByDate.values
            .filter { $0.nightDate >= rangeStart && $0.nightDate <= rangeEnd }
            .sorted { $0.nightDate < $1.nightDate }
    }

    /// Average % of asleep time spent in Deep sleep across the
    /// in-range summaries, or `nil` when the range has no Apple
    /// Watch data. Only summaries with non-zero `timeAsleep`
    /// contribute — otherwise the fraction is undefined and would
    /// drag the average toward zero.
    private var avgDeepPercent: Double? {
        let scored = sleepSummariesInRange.filter { $0.timeAsleep > 0 }
        guard !scored.isEmpty else { return nil }
        let sum = scored.reduce(0) { $0 + $1.fractionAsleep(in: .deep) }
        return (sum / Double(scored.count)) * 100
    }

    /// Same as `avgDeepPercent` but for REM.
    private var avgRemPercent: Double? {
        let scored = sleepSummariesInRange.filter { $0.timeAsleep > 0 }
        guard !scored.isEmpty else { return nil }
        let sum = scored.reduce(0) { $0 + $1.fractionAsleep(in: .rem) }
        return (sum / Double(scored.count)) * 100
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

    /// Hours-per-night threshold for this card. Reads the user's
    /// per-device preference (iCloud-synced) and falls back to the
    /// insurer-standard 4h when they haven't set one.
    private var complianceTargetHours: Double {
        library.complianceTarget(for: card.identification?.serialNumber)
    }

    /// Format a target as a short label — integers render without a
    /// decimal ("4h") and half-hour values keep one digit ("4.5h").
    /// Used in chart subtitles and compliance-card captions.
    private func formatComplianceTarget(_ hours: Double) -> String {
        if hours.rounded() == hours {
            return "\(Int(hours))h"
        }
        return String(format: "%.1fh", hours)
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
                        ahiHero
                        summaryCards
                        if library.intelligence.isReady {
                            CorrelationHintsCard(
                                stats: stats,
                                rangeStart: rangeStart,
                                rangeEnd: rangeEnd
                            )
                        }
                        ahiChart
                        // RERA Index sits next to AHI so the two
                        // event-rate trends read together —
                        // matches how the daily view groups AHI
                        // Events / RERA Events.
                        reraChart
                        usageChart
                        glasgowChart
                        // NED Mean follows Glasgow Index — both
                        // are breath-quality lines, both "lower is
                        // better". Same pairing the daily view uses.
                        nedChart
                        timeInApneaChart
                        // "Stage minutes per night" stacked bar
                        // chart sits next to Time in Apnea so the
                        // sleep-architecture story reads alongside
                        // the apnea metrics it's most often
                        // compared to.
                        if !sleepSummariesInRange.isEmpty {
                            sleepStagesChart
                        }
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
        .navigationTitle("Trends")
        .navigationSubtitle(library.displayName(for: card))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !allStats.isEmpty {
                FloatingActionBar(
                    items: floatingBarItems,
                    isEnabled: { item in
                        switch item {
                        case .sleepAnalysis: return !stats.isEmpty
                        default:             return true
                        }
                    },
                    onTap: handleFloatingBarTap
                )
            }
        }
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
                    Button(action: toggleTrendsAnalysis) {
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
                .help("Add or edit overall notes for this \(library.deviceType(for: library.card).displayName)")
            }
        }
        #endif
        // iOS + macOS: listen for Sleep Analysis requests posted
        // from the shared Options menu / File menu. macOS routes
        // through `library.pendingTrendsAnalysis`; iOS does the
        // same, and the sheet binding at ContentView picks it up.
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenTrendsAnalysis)) { _ in
            toggleTrendsAnalysis()
        }
    }

    /// Open Sleep Analysis when closed, close it when open. Keeps
    /// the Trends toolbar button, the floating-bar item on iOS, and
    /// the View-menu / ⌘⇧A shortcut in sync so a second tap on any
    /// of them dismisses the inspector/sheet instead of silently
    /// re-issuing the same request.
    private func toggleTrendsAnalysis() {
        if library.pendingTrendsAnalysis != nil {
            library.pendingTrendsAnalysis = nil
            return
        }
        guard !stats.isEmpty else { return }
        library.pendingTrendsAnalysis = TrendsAnalysisRequest(
            stats: stats,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
    }

    #if os(iOS)
    /// Items shown in the floating action bar. Sleep Analysis is
    /// only included when on-device intelligence is ready;
    /// `isEnabled` further dims it when the current range filter
    /// excludes every day.
    private var floatingBarItems: [FloatingActionBar.Item] {
        var items: [FloatingActionBar.Item] = []
        if library.intelligence.isReady {
            items.append(.sleepAnalysis)
        }
        items.append(.sleepJournal)
        return items
    }

    private func handleFloatingBarTap(_ item: FloatingActionBar.Item) {
        switch item {
        case .sleepAnalysis:
            NotificationCenter.default.post(name: .snorecardOpenTrendsAnalysis, object: nil)
        case .sleepJournal:
            NotificationCenter.default.post(name: .snorecardOpenDeviceNotes, object: nil)
        case .sessions, .therapyDetails:
            break
        }
    }
    #endif

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
                // iOS stacks the From/To pickers vertically so the
                // compact-style date controls don't have to share an
                // iPhone-width row with their labels. macOS keeps the
                // horizontal layout because the row is wider and the
                // stepper-style date field reads naturally inline.
                #if os(iOS)
                VStack(alignment: .leading, spacing: 8) {
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
                #else
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
                #endif
            }
        }
    }

    // MARK: - Aggregate cards

    /// Range-scoped hero mirroring the daily view's `EventDonutView` —
    /// big AHI number plus a stacked OA / H / CA bar across the whole
    /// range instead of a single night. Sits above the stat grid so the
    /// headline metric reads first, matching the Daily layout.
    private var ahiHero: some View {
        let days = stats.count
        // Pass raw averages through — `EventDonutView` honours the
        // user's CA-display preference internally so the donut head-
        // line and stacked bar both drop CA when hidden. The explain
        // sheet's `displayValue` and `averageValue` mirror that
        // adjustment so the tap target reads the same number.
        let avgAHI = days == 0 ? 0 : stats.reduce(0) { $0 + $1.ahi } / Double(days)
        let avgOAI = days == 0 ? 0 : stats.reduce(0) { $0 + $1.obstructiveApneaIndex } / Double(days)
        let avgHI = days == 0 ? 0 : stats.reduce(0) { $0 + $1.hypopneaIndex } / Double(days)
        let avgCAI = days == 0 ? 0 : stats.reduce(0) { $0 + $1.centralApneaIndex } / Double(days)
        let avgUAI = days == 0 ? 0 : stats.reduce(0) { $0 + $1.unspecifiedApneaIndex } / Double(days)
        let displayedAvgAHI = library.includesCentralEvents
            ? avgAHI
            : max(0, avgAHI - avgCAI)
        let explainCtx = TrendsExplainContext(
            metric: .ahi,
            displayValue: String(format: "%.2f events/hr", displayedAvgAHI),
            averageValue: displayedAvgAHI
        )
        return EventDonutView(
            ahi: avgAHI,
            obstructiveApneaIndex: avgOAI,
            centralApneaIndex: avgCAI,
            hypopneaIndex: avgHI,
            unspecifiedApneaIndex: avgUAI,
            headline: "AVG APNEA HYPOPNEA INDEX",
            onTap: explainTap(explainCtx)
        )
    }

    private var summaryCards: some View {
        let days = stats.count
        let totalUsage = stats.reduce(0) { $0 + $1.usageMinutes }
        let avgUsageMinutes = days == 0 ? 0 : totalUsage / Double(days)
        let target = complianceTargetHours
        let compliantDays = stats.filter { $0.usageHours >= target }.count
        let compliance = days == 0 ? 0 : Double(compliantDays) / Double(days)
        let avgSessions = averageSessionsPerNight()
        let avgGI = averaging(\.glasgowIndex)
        let avgRera = averaging(\.reraIndex)
        let avgNEDMean = nedAvgMean()
        let avgApnea: Double? = {
            let values = stats.compactMap { library.displayedTimeInApneaSeconds($0) }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }()
        // Source from `epap95` (target EPAP) so the Trends card
        // aligns with the EPAP card on the Daily view. The raw
        // `pressure95` field (measured mask pressure) still backs
        // the pressureChart trend below, where the clinical framing
        // is "what the mask actually held".
        let avgEPAP = averaging(\.epap95)
        let avgIPAP = averaging(\.ipap95)
        // Median-sourced per-day metrics stay in the median family
        // end-to-end — mean-of-medians would be a statistically
        // odd hybrid. See `medianAcrossDays(_:)` below.
        let medianMask = medianAcrossDays(\.pressureMedian)
        let avgFlow = averaging(\.flowLimit95)
        let avgLeak = averaging(\.leak95LPerMin)
        let avgLargeLeakPct = avgLargeLeakPercent()
        let medianTidal = medianAcrossDays(\.tidalVolume50)
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
                explain: TrendsExplainContext(
                    metric: .daysWithData,
                    displayValue: "\(days) night\(days == 1 ? "" : "s")",
                    averageValue: Double(days)
                )
            )
            let compliancePct = (compliance * 100).rounded()
            let targetLabel = formatComplianceTarget(target)
            card(
                "Compliance",
                value: "\(Int(compliancePct))%",
                subtitle: "\(compliantDays) of \(days) days ≥ \(targetLabel)",
                tint: compliance >= 0.7 ? .severityGood : library.eventColorPalette.severityMedium,
                explain: TrendsExplainContext(
                    metric: .compliance,
                    displayValue: "\(Int(compliancePct))% of nights ≥ \(targetLabel)",
                    averageValue: compliancePct
                )
            )
            card(
                "Usage / Night (AVG)",
                value: formatMinutes(avgUsageMinutes),
                subtitle: avgSessions.map { String(format: "%.1f sessions / night", $0) },
                tint: usageColor(avgUsageMinutes / 60),
                explain: TrendsExplainContext(
                    metric: .usage,
                    displayValue: formatMinutes(avgUsageMinutes),
                    averageValue: avgUsageMinutes / 60
                )
            )
            if let apnea = avgApnea {
                let pct = avgApneaPercent() ?? 0
                card(
                    "Time in Apnea (AVG)",
                    value: formatDurationShort(apnea),
                    subtitle: String(format: "%.2f%% of usage", pct),
                    tint: apneaColor(pct),
                    explain: TrendsExplainContext(
                        metric: .timeInApnea,
                        displayValue: String(format: "%.2f%% of usage", pct),
                        averageValue: pct
                    )
                )
            }
            // Apple Watch sleep-stage chips. Sit alongside the rest
            // of the night-aggregate cards so the per-stage averages
            // read at the same level as Compliance / Usage / Time
            // in Apnea. Both platforms: the data comes from the
            // sidecars iCloud Drive syncs, not from a HealthKit
            // query (which only runs on iOS). Tap-to-explain wiring
            // routes through the same `explainTap` helper as every
            // other Trends card.
            if let deepPct = avgDeepPercent {
                card(
                    "Deep Sleep (AVG)",
                    value: String(format: "%.0f%%", deepPct),
                    explain: TrendsExplainContext(
                        metric: .deepSleepPercent,
                        displayValue: String(format: "%.0f%%", deepPct),
                        averageValue: deepPct
                    )
                )
            }
            if let remPct = avgRemPercent {
                card(
                    "REM Sleep (AVG)",
                    value: String(format: "%.0f%%", remPct),
                    explain: TrendsExplainContext(
                        metric: .remSleepPercent,
                        displayValue: String(format: "%.0f%%", remPct),
                        averageValue: remPct
                    )
                )
            }
            // IPAP gets a separate card only when the range's
            // average IPAP sits meaningfully above EPAP — i.e.
            // some nights used bilevel or EPR-style therapy. On
            // plain CPAP the two averages match, so the single
            // EPAP card is relabelled "EPAP/IPAP" to make clear
            // that one value covers both.
            let showsDistinctIPAP: Bool = {
                guard let epap = avgEPAP, let ipap = avgIPAP else { return false }
                return ipap > epap + 0.05
            }()
            if let epap = avgEPAP {
                card(
                    showsDistinctIPAP ? "EPAP (AVG/95%)" : "EPAP/IPAP (AVG/95%)",
                    value: String(format: "%.1f cmH₂O", epap),
                    explain: TrendsExplainContext(
                        metric: .epap95,
                        displayValue: String(format: "%.1f cmH₂O", epap),
                        averageValue: epap
                    )
                )
            }
            if showsDistinctIPAP, let ipap = avgIPAP {
                card(
                    "IPAP (AVG/95%)",
                    value: String(format: "%.1f cmH₂O", ipap),
                    explain: TrendsExplainContext(
                        metric: .ipap95,
                        displayValue: String(format: "%.1f cmH₂O", ipap),
                        averageValue: ipap
                    )
                )
            }
            // Median across nights of each night's median mask
            // pressure. Stays in the median family to avoid a
            // mean-of-medians hybrid; reads as the "typical working
            // pressure" complement to the 95%-target EPAP/IPAP
            // averages above. Only shown when the standalone IPAP
            // card is hidden so the grid keeps the same card count
            // whether therapy is CPAP or bilevel.
            if !showsDistinctIPAP, let maskMedian = medianMask {
                card(
                    "Mask Pressure (Median)",
                    value: String(format: "%.1f cmH₂O", maskMedian),
                    explain: TrendsExplainContext(
                        metric: .maskPressureMedian,
                        displayValue: String(format: "%.1f cmH₂O", maskMedian),
                        averageValue: maskMedian
                    )
                )
            }
            if let flow = avgFlow {
                card(
                    "Flow Limit (AVG/95%)",
                    value: String(format: "%.2f", flow),
                    tint: flowLimitColor(flow),
                    explain: TrendsExplainContext(
                        metric: .flowLimit,
                        displayValue: String(format: "%.2f", flow),
                        averageValue: flow
                    )
                )
            }
            if let gi = avgGI {
                let contributor = glasgowTopContributor()
                card(
                    "Glasgow Index (AVG)",
                    value: String(format: "%.2f", gi),
                    subtitle: contributor.map {
                        String(format: "%.0f%% %@", $0.percent, $0.label)
                    },
                    tint: glasgowColor(gi),
                    explain: TrendsExplainContext(
                        metric: .glasgowIndex,
                        displayValue: String(format: "%.2f", gi),
                        averageValue: gi
                    )
                )
            }
            if let avgNED = avgNEDMean {
                let pct = avgNED * 100
                card(
                    "NED Mean (AVG)",
                    value: String(format: "%.1f%%", pct),
                    tint: nedMeanColor(pct),
                    explain: TrendsExplainContext(
                        metric: .nedMean,
                        displayValue: String(format: "%.1f%%", pct),
                        averageValue: pct
                    )
                )
            }
            if let rera = avgRera {
                card(
                    "RERA Index (AVG)",
                    value: String(format: "%.1f", rera),
                    tint: reraColor(rera),
                    explain: TrendsExplainContext(
                        metric: .reraIndex,
                        displayValue: String(format: "%.1f /hr", rera),
                        averageValue: rera
                    )
                )
            }
            if let tidal = medianTidal {
                let mL = tidal * 1000
                card(
                    "Tidal Volume (Median)",
                    value: String(format: "%.0f mL", mL),
                    tint: tidalVolumeColor(mL),
                    explain: TrendsExplainContext(
                        metric: .tidalVolume,
                        displayValue: String(format: "%.0f mL", mL),
                        averageValue: mL
                    )
                )
            }
            if let snoreBand = snoreBandAggregate() {
                card(
                    "Snore (AVG)",
                    value: snoreBand.level.label,
                    subtitle: snoreBand.subtitle,
                    tint: snoreLevelColor(snoreBand.level),
                    explain: avgSnore.map { snore in
                        TrendsExplainContext(
                            metric: .snore95,
                            displayValue: String(format: "%.1f", snore),
                            averageValue: snore
                        )
                    }
                )
            } else if let snore = avgSnore {
                // Fallback for ranges where no day in the window has
                // the band-seconds fields yet (older caches) — keep
                // the old 95th-percentile framing so the card isn't
                // blank until the user rebuilds the cache.
                card(
                    "Snore (AVG/95%)",
                    value: String(format: "%.1f", snore),
                    tint: snoreColor(snore),
                    explain: TrendsExplainContext(
                        metric: .snore95,
                        displayValue: String(format: "%.1f", snore),
                        averageValue: snore
                    )
                )
            }
            if let leak = avgLeak {
                card(
                    "Leak (AVG/95%)",
                    value: String(format: "%.0f L/min", leak),
                    tint: leakColor(leak),
                    explain: TrendsExplainContext(
                        metric: .leak95,
                        displayValue: String(format: "%.0f L/min", leak),
                        averageValue: leak
                    )
                )
            }
            if let largeLeak = avgLargeLeakPct {
                card(
                    "Large Leak (AVG)",
                    value: String(format: "%.0f%%", largeLeak),
                    subtitle: "of usage",
                    tint: largeLeak < 0.5 ? .severityGood : library.eventColorPalette.severityHigh,
                    explain: TrendsExplainContext(
                        metric: .largeLeak,
                        displayValue: String(format: "%.1f%% of usage", largeLeak),
                        averageValue: largeLeak
                    )
                )
            }
        }
    }

    /// Thin wrapper around `StatCard` so the Trends grid shares the
    /// same visual treatment and vertical alignment as the daily view.
    /// Passing an `explain` context wires the card up as a button
    /// that opens `MetricExplainSheet` with the range-scoped loader.
    private func card(
        _ label: String,
        value: String,
        subtitle: String? = nil,
        tint: Color = .primary,
        explain: TrendsExplainContext? = nil
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
    private func explainTap(_ ctx: TrendsExplainContext?) -> (() -> Void)? {
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
                source: .trends(
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
        case .ahi:              return "AHI (AVG)"
        case .glasgowIndex:     return "Glasgow Index (AVG)"
        case .reraIndex:        return "RERA Index (AVG)"
        case .nedMean:          return "NED Mean (AVG)"
        case .epap95:           return "EPAP (AVG/95%)"
        case .ipap95:           return "IPAP (AVG/95%)"
        case .maskPressureMedian: return "Mask Pressure (Median)"
        case .leak95:           return "Leak (AVG/95%)"
        case .largeLeak:        return "Large Leak (AVG)"
        case .tidalVolume:      return "Tidal Volume (Median)"
        case .snore95:          return "Snore (AVG/95%)"
        case .usage:            return "Usage / Night (AVG)"
        case .timeInApnea:      return "Time in Apnea (AVG)"
        case .flowLimit:        return "Flow Limit (AVG/95%)"
        case .compliance:       return "Compliance"
        case .daysWithData:     return "Days with Data"
        case .sessionsPerNight: return "Sessions / Night (AVG)"
        case .deepSleepPercent: return "Deep Sleep (AVG)"
        case .remSleepPercent:  return "REM Sleep (AVG)"
        }
    }

    // MARK: - Charts

    private var ahiChart: some View {
        chartSection(title: "AHI", subtitle: "events per hour") {
            Chart(stats, id: \.date) { stat in
                let value = library.displayedAHI(stat)
                BarMark(
                    x: .value("Day", stat.date, unit: .day),
                    y: .value("AHI", value)
                )
                .foregroundStyle(ahiColor(value))
            }
            .chartYScale(domain: 0 ... max(5, (stats.map { library.displayedAHI($0) }.max() ?? 0) * 1.2))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel { trendsYAxisLabel(for: value) }
                }
                AxisMarks(position: .leading, values: [5]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundStyle(.secondary)
                    AxisValueLabel { trendsYAxisLabel(for: value) }
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var usageChart: some View {
        let target = complianceTargetHours
        let targetLabel = formatComplianceTarget(target)
        return chartSection(
            title: "Usage",
            subtitle: "hours per night (dashed line: \(targetLabel) compliance)"
        ) {
            Chart(stats, id: \.date) { stat in
                BarMark(
                    x: .value("Day", stat.date, unit: .day),
                    y: .value("Hours", stat.usageHours)
                )
                .foregroundStyle(stat.usageHours >= target ? library.eventColorPalette.severityGood : library.eventColorPalette.severityHigh)
                RuleMark(y: .value("Compliance", target))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            }
            .chartYScale(domain: 0 ... max(8, (stats.map(\.usageHours).max() ?? 0) * 1.15))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel { trendsYAxisLabel(for: value) }
                }
            }
        }
    }

    private var glasgowChart: some View {
        let has = stats.contains { $0.glasgowIndex != nil }
        return chartSection(title: "Glasgow Index", subtitle: "lower is better") {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let gi = stat.glasgowIndex {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Index", gi)
                        )
                        .foregroundStyle(library.eventColorPalette.glasgowIndex)
                        .symbol(Circle())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { trendsYAxisLabel(for: value) }
                    }
                }
            } else {
                emptyPlaceholder("No Glasgow Index recorded.")
            }
        }
    }

    private var reraChart: some View {
        let has = stats.contains { $0.reraIndex != nil }
        return chartSection(title: "RERA Index", subtitle: nil) {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let rera = stat.reraIndex {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("RERA", rera)
                        )
                        .foregroundStyle(library.eventColorPalette.reraIndex)
                        .symbol(Circle())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { trendsYAxisLabel(for: value) }
                    }
                }
            } else {
                emptyPlaceholder("No RERA Index recorded.")
            }
        }
    }

    /// NED Mean per night, in percent. Mirrors `glasgowChart`'s
    /// shape (single line, `Circle` markers, palette tint) and the
    /// daily `NEDHourlyChart`'s axis units so a glance between the
    /// two surfaces tells the same story. Y-axis ticks carry a
    /// `%` suffix — the underlying values are NED-fraction × 100
    /// and dropping the unit would let the chart be mistaken for
    /// a raw 0-30 count.
    private var nedChart: some View {
        let has = stats.contains { $0.nedAnalysisBreakdown != nil }
        return chartSection(title: "NED Mean", subtitle: "lower is better") {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let ned = stat.nedAnalysisBreakdown?.nedMean {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("NED", ned * 100)
                        )
                        .foregroundStyle(library.eventColorPalette.reraIndex)
                        .symbol(Circle())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(v.formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) + "%")
                                    .font(.caption2.monospacedDigit())
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            } else {
                emptyPlaceholder("No NED Mean recorded.")
            }
        }
    }

    private var timeInApneaChart: some View {
        let has = stats.contains { library.displayedTimeInApneaSeconds($0) != nil }
        return chartSection(title: "Time in Apnea", subtitle: "minutes per night") {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let s = library.displayedTimeInApneaSeconds(stat) {
                        BarMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Minutes", s / 60)
                        )
                        .foregroundStyle(library.eventColorPalette.obstructive)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { trendsYAxisLabel(for: value) }
                    }
                }
            } else {
                emptyPlaceholder("No event-duration data recorded.")
            }
        }
    }

    /// Per-night stacked-bar of Deep / Core / REM minutes — the
    /// "Stage minutes per night" panel formerly inside the
    /// dedicated Apple Watch Sleep section, now part of the main
    /// chart list. Only built when `sleepSummariesInRange` is
    /// non-empty (caller gates rendering on the same condition).
    private var sleepStagesChart: some View {
        struct StackPoint: Identifiable {
            var id: String { "\(date.timeIntervalSinceReferenceDate)|\(stage)" }
            let date: Date
            let stage: String
            let minutes: Double
        }
        let points: [StackPoint] = sleepSummariesInRange.flatMap { summary in
            [
                StackPoint(date: summary.nightDate, stage: "Deep", minutes: summary.deepSeconds / 60),
                StackPoint(date: summary.nightDate, stage: "Core", minutes: summary.coreSeconds / 60),
                StackPoint(date: summary.nightDate, stage: "REM", minutes: summary.remSeconds / 60)
            ]
        }
        return chartSection(
            title: "Sleep Stages",
            subtitle: "minutes per night",
            legend: [
                LegendEntry(color: library.eventColorPalette.deepSleep, label: "Deep"),
                LegendEntry(color: library.eventColorPalette.coreSleep, label: "Core"),
                LegendEntry(color: library.eventColorPalette.remSleep, label: "REM")
            ]
        ) {
            Chart(points) { point in
                BarMark(
                    x: .value("Night", point.date, unit: .day),
                    y: .value("Minutes", point.minutes)
                )
                .foregroundStyle(by: .value("Stage", point.stage))
            }
            .chartForegroundStyleScale([
                "Deep": library.eventColorPalette.deepSleep,
                "Core": library.eventColorPalette.coreSleep,
                "REM": library.eventColorPalette.remSleep
            ])
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel { trendsYAxisLabel(for: value) }
                }
            }
        }
    }

    private var pressureChart: some View {
        let hasData = stats.contains { $0.pressure95 != nil }
        let pressureValues = stats.flatMap { [$0.pressureMedian, $0.pressure95].compactMap { $0 } }
        let yDomain: ClosedRange<Double> = {
            guard let lo = pressureValues.min(), let hi = pressureValues.max() else {
                return 0 ... 20
            }
            return (lo - 1) ... (hi + 1)
        }()
        return chartSection(
            title: "Mask Pressure",
            subtitle: "cmH₂O",
            legend: [
                LegendEntry(color: library.eventColorPalette.pressureMedian, label: "Median"),
                LegendEntry(color: library.eventColorPalette.pressureP95, label: "95th")
            ]
        ) {
            if hasData {
                Chart(stats, id: \.date) { stat in
                    if let p95 = stat.pressure95 {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("P95", p95),
                            series: .value("Series", "95th")
                        )
                        .foregroundStyle(library.eventColorPalette.pressureP95)
                        .symbol(Circle())
                    }
                    if let median = stat.pressureMedian {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Median", median),
                            series: .value("Series", "Median")
                        )
                        .foregroundStyle(library.eventColorPalette.pressureMedian)
                        .symbol(Circle())
                    }
                }
                .chartYScale(domain: yDomain)
                .chartForegroundStyleScale([
                    "95th": library.eventColorPalette.pressureP95,
                    "Median": library.eventColorPalette.pressureMedian
                ])
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { trendsYAxisLabel(for: value) }
                    }
                }
            } else {
                emptyPlaceholder("No pressure data recorded.")
            }
        }
    }

    private var flowLimitChart: some View {
        let has = stats.contains { $0.flowLimit95 != nil }
        return chartSection(
            title: "Flow Limit",
            subtitle: "0–1 scale",
            legend: [
                LegendEntry(color: library.eventColorPalette.flowLimit, label: "95th")
            ]
        ) {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let fl = stat.flowLimit95 {
                        BarMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Flow Limit", fl)
                        )
                        .foregroundStyle(library.eventColorPalette.flowLimit)
                    }
                }
                .chartYScale(domain: 0...max(0.2, (stats.compactMap(\.flowLimit95).max() ?? 0) * 1.2))
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { trendsYAxisLabel(for: value) }
                    }
                }
            } else {
                emptyPlaceholder("No flow-limit data recorded.")
            }
        }
    }

    private var leakChart: some View {
        let hasLeak = stats.contains { $0.leak95LPerMin != nil }
        return chartSection(
            title: "Leak",
            subtitle: "L/min",
            legend: [
                LegendEntry(color: library.eventColorPalette.leak, label: "95th")
            ]
        ) {
            if hasLeak {
                Chart(stats, id: \.date) { stat in
                    if let leak = stat.leak95LPerMin {
                        BarMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Leak", leak)
                        )
                        .foregroundStyle(library.eventColorPalette.leak)
                    }
                    RuleMark(y: .value("Threshold", 24))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { trendsYAxisLabel(for: value) }
                    }
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
                        .foregroundStyle(pct > 5 ? library.eventColorPalette.severityMedium : library.eventColorPalette.severityLow)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { trendsYAxisLabel(for: value) }
                    }
                }
            } else {
                emptyPlaceholder("No large-leak data recorded.")
            }
        }
    }

    private var tidalVolumeChart: some View {
        let has = stats.contains { $0.tidalVolume50 != nil }
        let tidalValues = stats.compactMap { $0.tidalVolume50.map { $0 * 1000 } }
        let yDomain: ClosedRange<Double> = {
            guard let lo = tidalValues.min(), let hi = tidalValues.max() else {
                return 0 ... 800
            }
            return (lo - 100) ... (hi + 100)
        }()
        return chartSection(
            title: "Tidal Volume",
            subtitle: "mL",
            legend: [
                LegendEntry(color: library.eventColorPalette.tidalVolume, label: "Median")
            ]
        ) {
            if has {
                Chart(stats, id: \.date) { stat in
                    if let tv = stat.tidalVolume50 {
                        LineMark(
                            x: .value("Day", stat.date, unit: .day),
                            y: .value("Tidal Volume", tv * 1000)
                        )
                        .foregroundStyle(library.eventColorPalette.tidalVolume)
                        .symbol(Circle())
                    }
                }
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel { trendsYAxisLabel(for: value) }
                    }
                }
            } else {
                emptyPlaceholder("No tidal-volume data recorded.")
            }
        }
    }

    /// One row in the colour-key legend rendered below a Trends
    /// chart. Mirrors the per-hour chart legends on the Daily view
    /// so the two pages read as one visual set.
    fileprivate struct LegendEntry: Identifiable {
        let id = UUID()
        let color: Color
        let label: String
    }

    /// Card chrome matching `HourlyChartCard` / `AHIHourlyChart` on
    /// the Daily view — small uppercase caption title, tertiary
    /// subtitle, an inset-plate background, and an optional colour-
    /// key legend below the chart so series identities ride at the
    /// foot rather than in the chart description.
    @ViewBuilder
    private func chartSection<C: View>(
        title: String,
        subtitle: String?,
        legend: [LegendEntry] = [],
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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

            if !legend.isEmpty {
                FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(legend) { entry in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(entry.color)
                                .frame(width: 8, height: 8)
                            Text(entry.label)
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12))
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
        // Label every day in the range — matches the daily-view
        // hourly charts where every hour gets its own label
        // regardless of width. SwiftUI Charts handles layout when
        // the labels run together; the user explicitly preferred
        // a complete x-axis to a strided one.
        let cal = Calendar.current
        var dates: [Date] = []
        var current = cal.startOfDay(for: rangeStart)
        let end = cal.startOfDay(for: rangeEnd)
        while current <= end {
            dates.append(current)
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return dates
    }

    /// Lightweight "this chart has nothing to plot" affordance —
    /// small tertiary glyph above a caption, sized to fit inside the
    /// chart frame. Deliberately *not* the full `IssueCallout` hero
    /// surface: a 260-pt centered placeholder would dwarf the chart
    /// card it lives inside.
    private func emptyPlaceholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: - Helpers

    private var dateRangeLabel: String {
        guard let first = stats.first?.date, let last = stats.last?.date else { return "" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return formatRangeDate(first)
        }
        return "\(formatRangeDate(first)) – \(formatRangeDate(last))"
    }

    private func formatRangeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let dateYear = calendar.component(.year, from: date)
        if dateYear == currentYear {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Mean number of BRP sessions across days inside the current range
    /// that recorded usage. Mirrors the "sessions" count surfaced on
    /// the daily detail view.
    private func averageSessionsPerNight() -> Double? {
        let start = rangeStart, end = rangeEnd
        // `stats.maskEvents` is the kept-session count after the
        // aggregate's manual-exclusion + brief-session filters, so
        // averaging it agrees with the daily Usage subtitle.
        let counts = card.days
            .filter { $0.date >= start && $0.date <= end }
            .compactMap { $0.stats?.maskEvents }
            .filter { $0 > 0 }
        guard !counts.isEmpty else { return nil }
        return Double(counts.reduce(0, +)) / Double(counts.count)
    }

    private func averaging(_ keyPath: KeyPath<DailyStatistics, Double?>) -> Double? {
        let values = stats.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Median across days of a per-day `Double?` keyPath. Used for
    /// sources that are themselves per-night medians (Mask Pressure,
    /// Tidal Volume) — taking the mean of medians is a statistically
    /// awkward hybrid, so we stay in the median family end-to-end.
    private func medianAcrossDays(_ keyPath: KeyPath<DailyStatistics, Double?>) -> Double? {
        let values = stats.compactMap { $0[keyPath: keyPath] }.sorted()
        guard !values.isEmpty else { return nil }
        let count = values.count
        if count.isMultiple(of: 2) {
            return (values[count / 2 - 1] + values[count / 2]) / 2
        }
        return values[count / 2]
    }

    /// Dominant Glasgow sub-index across the range and its share of
    /// the total score. Surfaced as the Glasgow card's subtitle
    /// ("47% top-heavy") so the headline number is paired with the
    /// breath characteristic driving it. Per-day breakdowns are
    /// averaged with equal weight — the per-inspiration weights the
    /// underlying `computeDay` uses aren't persisted on
    /// `DailyStatistics`, so days contribute evenly here.
    private func glasgowTopContributor() -> (label: String, percent: Double)? {
        let breakdowns = stats.compactMap(\.glasgowBreakdown)
        guard !breakdowns.isEmpty else { return nil }

        var acc = GlasgowIndex.BreakdownAccumulator()
        for b in breakdowns { acc.add(b, weight: 1) }
        let avg = acc.finalize(totalWeight: Double(breakdowns.count))
        return DayDetailView.glasgowTopContributor(avg)
    }

    /// Mean of the per-night `nedMean` across the visible range
    /// (in fraction units — caller multiplies by 100 for display).
    /// Days without a NED breakdown drop out of the average, same
    /// as every other `averaging(\.something)` accessor on this
    /// view.
    private func nedAvgMean() -> Double? {
        let values = stats.compactMap { $0.nedAnalysisBreakdown?.nedMean }
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

    /// Threshold bands for the AHI trend chart. The bands themselves
    /// (2 / 5 events-per-hour) are clinical, but which colours stand
    /// in for "good/watch/bad" adapts to the active palette so the
    /// chart blends into the themed Trends page instead of forcing
    /// the global severity palette in.
    private func ahiColor(_ ahi: Double) -> Color {
        let palette = library.eventColorPalette
        switch ahi {
        case ..<2: return palette.severityGood
        case ..<5: return palette.severityLow
        default:   return palette.severityHigh
        }
    }

    // MARK: - Stat-card severity tints
    //
    // Clinical thresholds below stay fixed; only the amber/red
    // cues route through `library.eventColorPalette` so the card
    // backgrounds adapt to the active theme. `.severityGood` keeps
    // the global neutral colour because StatCard treats it as the
    // implicit default and doesn't tint the plate at all, so green
    // never actually renders as a background.

    /// Leak-severity palette — green under 5 L/min, amber 5–23, red ≥ 24.
    private func leakColor(_ leak: Double) -> Color {
        switch leak {
        case ..<5:  return .severityGood
        case ..<24: return library.eventColorPalette.severityLow
        default:    return library.eventColorPalette.severityHigh
        }
    }

    /// Flow-limit palette — green when the 95th percentile rounds to
    /// 0.00, amber in between, red ≥ 0.10.
    private func flowLimitColor(_ value: Double) -> Color {
        switch value {
        case ..<0.005: return .severityGood
        case ..<0.10:  return library.eventColorPalette.severityLow
        default:       return library.eventColorPalette.severityHigh
        }
    }

    /// RERA Index palette — same thresholds as the day-view card
    /// (≤ 5/hr controlled, ≤ 15/hr mild, > 15/hr elevated).
    private func reraColor(_ value: Double) -> Color {
        switch value {
        case ..<5:  return .severityGood
        case ..<15: return library.eventColorPalette.severityLow
        default:    return library.eventColorPalette.severityHigh
        }
    }

    /// NED Mean palette — same thresholds as the day-view card
    /// (< 15% normal, 15–25% elevated, ≥ 25% typical breath is
    /// itself flow-limited).
    private func nedMeanColor(_ pct: Double) -> Color {
        switch pct {
        case ..<15: return .severityGood
        case ..<25: return library.eventColorPalette.severityLow
        default:    return library.eventColorPalette.severityHigh
        }
    }

    /// Glasgow Index palette — neutral under 2, amber 2–3, red ≥ 3.
    private func glasgowColor(_ value: Double) -> Color {
        switch value {
        case ..<2.0: return .severityGood
        case ..<3.0: return library.eventColorPalette.severityLow
        default:     return library.eventColorPalette.severityHigh
        }
    }

    /// Usage palette — red under 4h (non-compliant), amber 4–7h (short),
    /// green 7–9h (target), amber 9–10h (long), red ≥ 10h (over-use).
    private func usageColor(_ hours: Double) -> Color {
        switch hours {
        case ..<4:  return library.eventColorPalette.severityHigh
        case ..<7:  return library.eventColorPalette.severityLow
        case ..<9:  return .severityGood
        case ..<10: return library.eventColorPalette.severityLow
        default:    return library.eventColorPalette.severityHigh
        }
    }

    /// Time-in-apnea palette (percent of usage) — green < 1 %, amber
    /// 1–3 %, red ≥ 3 %. Tighter than the clinical AHI bands.
    private func apneaColor(_ percent: Double) -> Color {
        switch percent {
        case ..<1: return .severityGood
        case ..<3: return library.eventColorPalette.severityLow
        default:   return library.eventColorPalette.severityHigh
        }
    }

    /// Tidal-volume palette (median mL) — two-sided: green in the 420–
    /// 600 mL sweet spot, amber on either side of that window, red at
    /// the extremes.
    /// Snore palette — same boundaries as the Daily view so the
    /// average card tints the same way the per-night card would.
    /// Still used as a fallback when the range contains only
    /// cached days from builds before the band-seconds fields.
    private func snoreColor(_ index: Double) -> Color {
        switch index {
        case ..<1: return .severityGood
        case ..<3: return library.eventColorPalette.severityLow
        default:   return library.eventColorPalette.severityHigh
        }
    }

    /// Mirrors `DayDetailView.snoreLevelColor` so Trends and Daily
    /// agree on which levels wash the card amber or red.
    private func snoreLevelColor(_ level: SnoreLevel) -> Color {
        switch level {
        case .quiet:    return .severityGood
        case .mild:     return library.eventColorPalette.severityLow
        case .moderate: return library.eventColorPalette.severityLow
        case .loud:     return library.eventColorPalette.severityHigh
        }
    }

    /// Roll the per-day snore band seconds up across the range and
    /// classify the whole window. Returns nil when no day in the
    /// range has the band-seconds fields populated (e.g. the whole
    /// window predates the feature and no rebuild has run yet).
    private func snoreBandAggregate() -> (level: SnoreLevel, subtitle: String?)? {
        var moderate: Double = 0
        var loud: Double = 0
        var usageSeconds: Double = 0
        var sawAny = false
        for stat in stats where stat.hasUsage {
            guard let mod = stat.snoreModerateSeconds,
                  let lo = stat.snoreLoudSeconds else { continue }
            moderate += mod
            loud += lo
            usageSeconds += stat.usageMinutes * 60
            sawAny = true
        }
        guard sawAny, usageSeconds > 0 else { return nil }
        guard let level = SnoreLevel.classify(
            moderateSeconds: moderate,
            loudSeconds: loud,
            usageSeconds: usageSeconds
        ) else { return nil }
        let subtitle = SnoreLevel.subtitle(
            moderateSeconds: moderate,
            loudSeconds: loud,
            usageSeconds: usageSeconds
        )
        return (level, subtitle)
    }

    private func tidalVolumeColor(_ mL: Double) -> Color {
        switch mL {
        case ..<350: return library.eventColorPalette.severityHigh
        case ..<420: return library.eventColorPalette.severityLow
        case ...600: return .severityGood
        case ...700: return library.eventColorPalette.severityLow
        default:     return library.eventColorPalette.severityHigh
        }
    }

    /// Average per-night percent of usage spent in apnea, computed
    /// across days that recorded both usage and an apnea-seconds value.
    /// Routes through `library.displayedTimeInApneaSeconds(_:)` so
    /// hiding CA events also drops the central-apnea durations from
    /// the percentage.
    private func avgApneaPercent() -> Double? {
        let values = stats.compactMap { stat -> Double? in
            guard let seconds = library.displayedTimeInApneaSeconds(stat),
                  stat.usageMinutes > 0 else { return nil }
            return seconds / (stat.usageMinutes * 60) * 100
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
