import SwiftUI
import Charts
import SnorecardKit
import os.log

private let waveformLog = Logger(subsystem: "com.vmstan.Snorecard", category: "Waveform")

struct DayDetailView: View {
    let day: ResMedDay
    @Environment(Library.self) private var library
    @State private var loadedWaveform: WaveformBundle?
    @State private var loadError: String?
    @State private var isShowingSettings = false
    @State private var isShowingNotes = false
    @State private var isShowingSleepAnalysis = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let error = loadError {
                    Text(error)
                        .foregroundStyle(.red)
                } else if loadedWaveform == nil {
                    // Placeholder only while the bundle is still
                    // decoding — once it lands the summary cards,
                    // hourly charts, and Advanced Charting button
                    // are all the user needs inline. The high-
                    // resolution waveform + session timeline now
                    // live behind that button, not here.
                    waveformLoadingPlaceholder
                }
            }
            .padding(20)
        }
        .navigationTitle(navigationTitleText)
        .navigationSubtitle(deviceSubtitle)
        #if os(iOS)
        // Force inline title mode so the date string sits in the
        // nav bar consistently — UINavigationController otherwise
        // flips between centered and leading-aligned depending on
        // how long the weekday/month/day string is.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        // macOS keeps these as discrete toolbar buttons because
        // there's room. Both iOS (via the shared Options menu)
        // and macOS funnel through the same notifications so the
        // shared inspector in `ContentView` owns the display
        // state; this view just announces intent.
        .toolbar {
            if library.intelligence.isReady {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(
                            name: .snorecardOpenSleepAnalysis,
                            object: nil
                        )
                    } label: {
                        Label("Sleep Analysis", systemImage: "sparkles")
                    }
                    .help("On-device AI summary of this night")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NotificationCenter.default.post(
                        name: .snorecardOpenDailyNotes,
                        object: nil
                    )
                } label: {
                    Label("Sleep Journal", systemImage: "note.text")
                }
                .help("Add or edit your sleep journal for this night")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NotificationCenter.default.post(
                        name: .snorecardOpenDailySettings,
                        object: nil
                    )
                } label: {
                    Label("Therapy Details", systemImage: "gauge.with.needle")
                }
                .help("Show therapy details for this night")
            }
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: $isShowingNotes) {
            NavigationStack {
                NotesCard(day: day)
                    .padding(20)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            CloseSheetButton { isShowingNotes = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingSettings) {
            // iOS `.inspector` collapses into the parent navigation
            // stack and bleeds its title/toolbar into the day header,
            // so settings also presents as a sheet on iPhone.
            DailySettingsInspector(
                settings: day.stats?.settings,
                date: day.date,
                productName: day.stats?.productName
                    ?? library.card?.identification?.productName,
                serialNumber: library.card?.identification?.serialNumber,
                deviceAlias: deviceAliasForInspector
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingSleepAnalysis) {
            NavigationStack {
                NightSummaryCard(day: day)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            CloseSheetButton { isShowingSleepAnalysis = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // Bridges from the shared Options menu's daily entries —
        // ContentView posts these whenever the user picks Notes,
        // Sleep Analysis, or Device Settings out of the iOS
        // ellipsis menu.
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenDailyNotes)) { _ in
            isShowingNotes = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenDailySettings)) { _ in
            isShowingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenSleepAnalysis)) { _ in
            isShowingSleepAnalysis = true
        }
        #endif
        .task(id: day.id) {
            await loadAllSessions()
        }
    }

    /// Device name pulled from the currently-loaded card so the daily
    /// view's nav bar shows which machine the data belongs to.
    private var deviceSubtitle: String {
        guard let card = library.card else { return "" }
        return library.displayName(for: card)
    }

    /// User-set alias (set via Rename Device) for the current card,
    /// or nil when the user hasn't picked one. The Device section of
    /// the settings inspector skips the row when this is nil so the
    /// default product name doesn't duplicate across rows.
    private var deviceAliasForInspector: String? {
        guard let serial = library.card?.identification?.serialNumber,
              let alias = library.deviceNameOverrides[serial],
              !alias.isEmpty
        else { return nil }
        return alias
    }

    /// Replaces the bare `ProgressView` placeholder with a centered
    /// icon + headline + progress cluster that matches the sidebar
    /// loading screen's voice.
    private var waveformLoadingPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            VStack(spacing: 4) {
                Text("Analyzing breath waveforms")
                    .font(.headline)
                Text(waveformLoadingSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            ProgressView()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(.vertical, 20)
    }

    private var waveformLoadingSubtitle: String {
        let brp = day.files(of: .breath).count
        if brp == 0 {
            return "Reading the night's sessions…"
        }
        return "\(brp) session\(brp == 1 ? "" : "s") from this night"
    }

    @ViewBuilder
    private var header: some View {
        if let stats = day.stats, stats.hasUsage {
            VStack(alignment: .leading, spacing: 12) {
                EventDonutView(stats: stats)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    StatCard(
                        label: "Usage",
                        value: formatHours(stats.usageHours),
                        subtitle: sessionCountLabel,
                        tint: usageColor(stats.usageHours),
                        onTap: explainTap(.usage)
                    )
                    if let apneaSeconds = stats.timeInApneaSeconds {
                        let percent = apneaSeconds / (stats.usageMinutes * 60) * 100
                        StatCard(
                            label: "Time in Apnea",
                            value: formatDurationShort(apneaSeconds),
                            subtitle: String(format: "%.2f%% of usage", percent),
                            tint: apneaColor(percent),
                            onTap: explainTap(.timeInApnea)
                        )
                    }
                    if let gi = stats.glasgowIndex {
                        StatCard(
                            label: "Glasgow Index",
                            value: String(format: "%.2f", gi),
                            tint: glasgowColor(gi),
                            onTap: explainTap(.glasgowIndex)
                        )
                    }

                    if let epap = stats.epap95 {
                        let support = stats.ipap95.map { max(0, $0 - epap) }
                        StatCard(
                            label: "Pressure (95%)",
                            value: String(format: "%.1f cmH₂O", epap),
                            subtitle: support.map { String(format: "Support %.1f", $0) },
                            onTap: explainTap(.pressure95)
                        )
                    }
                    if let fl = stats.flowLimit95 {
                        StatCard(
                            label: "Flow Limit (95%)",
                            value: String(format: "%.2f", fl),
                            tint: flowLimitColor(fl),
                            onTap: explainTap(.flowLimit)
                        )
                    }
                    if let tv = stats.tidalVolume50 {
                        let mL = tv * 1000
                        StatCard(
                            label: "Tidal Volume (Median)",
                            value: String(format: "%.0f mL", mL),
                            tint: tidalVolumeColor(mL),
                            onTap: explainTap(.tidalVolume)
                        )
                    }
                    if let leak = stats.leak95LPerMin {
                        StatCard(
                            label: "Leak (95%)",
                            value: String(format: "%.0f L/min", leak),
                            tint: leakColor(leak),
                            onTap: explainTap(.leak95)
                        )
                    }
                    if let largeLeak = stats.largeLeakSeconds {
                        let usageSeconds = stats.usageMinutes * 60
                        let percent = usageSeconds > 0 ? (largeLeak / usageSeconds * 100) : 0
                        StatCard(
                            label: "Large Leak",
                            value: String(format: "%.0f%%", percent),
                            subtitle: formatDurationShort(largeLeak),
                            tint: percent < 0.5 ? .severityGood : .severityHigh,
                            onTap: explainTap(.largeLeak)
                        )
                    }
                }

                // Per-hour breakdowns sit below the stat grid so
                // the cards aren't pushed offscreen by them. Order
                // — events, leak, flow limit, pressure — goes from
                // the most-diagnostic metric (events) to the
                // trajectory one (pressure) so a scan down the
                // column reads most-important-first.
                if let bundle = loadedWaveform, !bundle.events.isEmpty {
                    AHIHourlyChart(
                        events: bundle.events,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                if let bundle = loadedWaveform, !bundle.flatLeak.isEmpty {
                    LeakHourlyChart(
                        leak: bundle.flatLeak,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                if let bundle = loadedWaveform, !bundle.flatFlowLimitation.isEmpty {
                    FlowLimitHourlyChart(
                        flowLimit: bundle.flatFlowLimitation,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                if let bundle = loadedWaveform, !bundle.flatPressure.isEmpty {
                    PressureHourlyChart(
                        pressure: bundle.flatPressure,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }

                // Detailed Statistics + Advanced Charting both
                // spawn a secondary window (macOS) or sheet (iOS)
                // so the day view itself stays focused on metrics
                // and hourly charts. macOS lays them out side-by-
                // side because there's room; iOS stacks them to
                // keep the labels readable on narrow screens.
                if loadedWaveform != nil {
                    summaryActionButtons
                }
            }
        } else if !day.files.isEmpty {
            Text("No summary data available for this day.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
        }
    }

    /// Detailed Statistics + Advanced Charting action row. macOS
    /// places them side-by-side because there's plenty of toolbar
    /// width; iOS stacks them vertically so the labels stay
    /// readable on a phone-width screen.
    @ViewBuilder
    private var summaryActionButtons: some View {
        let summaryTable: DailySignalSummaryTable? = {
            guard let bundle = loadedWaveform, !bundle.signalSummary.isEmpty else {
                return nil
            }
            return DailySignalSummaryTable(
                payload: DetailedStatisticsPayload(
                    dayDate: day.date,
                    deviceName: library.card.map { library.displayName(for: $0) },
                    rows: bundle.signalSummary
                )
            )
        }()
        let advancedChartingButton = AdvancedChartingButton(
            payload: AdvancedChartingPayload(
                dayDate: day.date,
                deviceName: library.card.map { library.displayName(for: $0) },
                brpURLs: day.files(of: .breath).map(\.url),
                pldURLs: day.files(of: .physiological).map(\.url),
                eveURLs: day.files(of: .events).map(\.url)
            )
        )

        #if os(iOS)
        VStack(alignment: .leading, spacing: 10) {
            summaryTable
            advancedChartingButton
        }
        #else
        HStack(spacing: 10) {
            summaryTable
            advancedChartingButton
        }
        #endif
    }

    /// Return a tap handler for an explainable metric when Apple
    /// Intelligence is available on this device, `nil` otherwise.
    /// Sets `library.pendingExplain`; `ContentView` owns the
    /// actual presentation (sheet on iOS, inspector pane on
    /// macOS) so both platforms share one routing path.
    ///
    /// Toggle behaviour: tapping the card that is already
    /// showing in the inspector dismisses it, matching how the
    /// other inspector panes (notes, settings, …) already work
    /// via `toggleInspector`. Tapping a different card swaps
    /// content in place.
    private func explainTap(_ metric: ExplainableMetric) -> (() -> Void)? {
        guard library.intelligence.isReady else { return nil }
        return {
            let request = ExplainRequest(
                metric: metric,
                displayLabel: Self.displayLabel(for: metric),
                displayValue: displayValue(for: metric),
                valueCaption: "Your value for this night",
                source: .day(dayID: day.id)
            )
            if library.pendingExplain == request {
                library.pendingExplain = nil
            } else {
                library.pendingExplain = request
            }
        }
    }

    static func displayLabel(for metric: ExplainableMetric) -> String {
        switch metric {
        case .ahi:              return "AHI"
        case .glasgowIndex:     return "Glasgow Index"
        case .pressure95:       return "Pressure (95%)"
        case .epr:              return "Pressure Support"
        case .leak95:           return "Leak (95%)"
        case .largeLeak:        return "Large Leak"
        case .tidalVolume:      return "Tidal Volume"
        case .usage:            return "Usage"
        case .timeInApnea:      return "Time in Apnea"
        case .flowLimit:        return "Flow Limit (95%)"
        // Overview-only metrics fall back to their enum label —
        // the daily view never opens the sheet for these, but
        // the switch has to be exhaustive.
        case .compliance:       return "Compliance"
        case .daysWithData:     return "Days with Data"
        case .sessionsPerNight: return "Sessions / Night"
        }
    }

    private func displayValue(for metric: ExplainableMetric) -> String {
        guard let stats = day.stats else { return "—" }
        switch metric {
        case .ahi:          return String(format: "%.1f", stats.ahi)
        case .glasgowIndex:
            return stats.glasgowIndex.map { String(format: "%.2f", $0) } ?? "—"
        case .pressure95:
            // Matches the "Pressure (95%)" StatCard — sourced from
            // `epap95`, not `pressure95`. See DayDetailView.header.
            return stats.epap95.map { String(format: "%.1f cmH₂O", $0) } ?? "—"
        case .epr:
            guard let ipap = stats.ipap95, let epap = stats.epap95 else { return "—" }
            return String(format: "%.1f cmH₂O", max(0, ipap - epap))
        case .leak95:
            return stats.leak95LPerMin.map { String(format: "%.0f L/min", $0) } ?? "—"
        case .largeLeak:
            guard let seconds = stats.largeLeakSeconds, stats.usageMinutes > 0
            else { return "—" }
            let pct = seconds / (stats.usageMinutes * 60) * 100
            return String(format: "%.0f%%", pct)
        case .tidalVolume:
            return stats.tidalVolume50.map { String(format: "%.0f mL", $0 * 1000) } ?? "—"
        case .usage:
            return formatHours(stats.usageHours)
        case .timeInApnea:
            guard let seconds = stats.timeInApneaSeconds, stats.usageMinutes > 0
            else { return "—" }
            let pct = seconds / (stats.usageMinutes * 60) * 100
            return String(format: "%.2f%% of usage", pct)
        case .flowLimit:
            return stats.flowLimit95.map { String(format: "%.2f", $0) } ?? "—"
        // Overview-only metrics have no per-day value — the sheet
        // path on DayDetailView never hits these cases, but
        // exhaustive switching still requires them.
        case .compliance, .daysWithData, .sessionsPerNight:
            return "—"
        }
    }

    private func formatHours(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(m)m"
    }

    /// Compact "Xh Ym" / "X min" / "X sec" duration formatter used by the
    /// Time in Apnea and Large Leak cards.
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

    private var sessionCountLabel: String {
        let count = day.files(of: .breath).count
        return "\(count) session\(count == 1 ? "" : "s")"
    }

    /// Full weekday + month + day, with the year appended only when the
    /// day isn't in the current calendar year.
    private var navigationTitleText: Text {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let dayYear = calendar.component(.year, from: day.date)
        if dayYear == currentYear {
            return Text(day.date, format: .dateTime.weekday(.wide).day().month(.wide))
        }
        return Text(day.date, format: .dateTime.weekday(.wide).day().month(.wide).year())
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
    /// 600 mL sweet spot (roughly 7 mL/kg IBW for an average adult),
    /// amber on either side of the healthy window, red at the extremes.
    private func tidalVolumeColor(_ mL: Double) -> Color {
        switch mL {
        case ..<350: .severityHigh
        case ..<420: .severityLow
        case ...600: .severityGood
        case ...700: .severityLow
        default: .severityHigh
        }
    }

    private func loadAllSessions() async {
        loadedWaveform = nil
        loadError = nil

        let brpURLs = day.files(of: .breath).map(\.url)
        let pldURLs = day.files(of: .physiological).map(\.url)
        let eveURLs = day.files(of: .events).map(\.url)

        waveformLog.info("loadAllSessions start day=\(day.date, privacy: .public) brp=\(brpURLs.count) pld=\(pldURLs.count) eve=\(eveURLs.count)")

        guard !brpURLs.isEmpty else {
            loadError = "No breath waveform for this day."
            return
        }

        do {
            // Detached so the load isn't cancelled by view recomposition —
            // on iOS the structured `Task` was getting killed mid-load and
            // the view would stay stuck on "Decoding sessions…" forever.
            let bundle = try await Task.detached(priority: .userInitiated) {
                try WaveformBundle.load(
                    brpFiles: brpURLs,
                    pldFiles: pldURLs,
                    eveFiles: eveURLs
                )
            }.value

            waveformLog.info("loadAllSessions done sessions=\(bundle.sessions.count) events=\(bundle.events.count)")
            self.loadedWaveform = bundle
        } catch {
            waveformLog.error("loadAllSessions failed: \(String(describing: error), privacy: .public)")
            self.loadError = String(describing: error)
        }
    }
}
