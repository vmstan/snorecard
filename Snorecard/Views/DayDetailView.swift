import SwiftUI
import Charts
import SnorecardKit
import os.log

private let waveformLog = Logger(subsystem: "com.vmstan.Snorecard", category: "Waveform")

struct DayDetailView: View {
    let day: ResMedDay
    @Environment(Library.self) private var library
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var loadedWaveform: WaveformBundle?
    @State private var loadError: String?
    @State private var isShowingSettings = false
    @State private var isShowingNotes = false
    @State private var isShowingSleepAnalysis = false
    @State private var isShowingSessions = false

    /// Mirror of `DailyStatistics.aggregate(minSessionSeconds:)` so
    /// the daily charts drop the same brief sessions the aggregate
    /// does. Centralised here (as well as in `SessionListSheet`) so
    /// the rule is in one place per platform layer.
    private static let briefSessionSeconds: Double = 120

    /// Map the user's `excludedSessionKeys` and the auto-exclude
    /// rule onto the loaded bundle's per-session UUIDs. Empty when
    /// no bundle is loaded yet.
    private var inactiveSessionIDs: Set<UUID> {
        guard let bundle = loadedWaveform else { return [] }
        let excludedKeys = library.excludedSessionKeys
        var ids: Set<UUID> = []
        for session in bundle.sessions {
            if session.duration < Self.briefSessionSeconds {
                ids.insert(session.id)
                continue
            }
            let parts = session.sourceFilename.split(separator: "_")
            guard parts.count >= 2,
                  parts[0].count == 8,
                  parts[1].count == 6 else { continue }
            let key = "\(parts[0])_\(parts[1])"
            if excludedKeys.contains(key) {
                ids.insert(session.id)
            }
        }
        return ids
    }

    /// `loadedWaveform` with brief and excluded sessions stripped —
    /// used by the daily charts so the visualisation matches the
    /// stat cards' filtered totals.
    private var displayedBundle: WaveformBundle? {
        loadedWaveform?.filteringInactiveSessions(inactiveSessionIDs)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let error = loadError {
                    waveformErrorPlaceholder(error)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingActionBar(
                items: floatingBarItems,
                onTap: handleFloatingBarTap
            )
        }
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
                        name: .snorecardOpenSessions,
                        object: nil
                    )
                } label: {
                    Label("Therapy Sessions", systemImage: "clock")
                }
                .help("Show every therapy session recorded for this night")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NotificationCenter.default.post(
                        name: .snorecardOpenDailySettings,
                        object: nil
                    )
                } label: {
                    Label("Therapy Details", systemImage: "fan")
                }
                .help("Show therapy details for this night")
            }
        }
        // View-menu bridges — the macOS menu posts these so the day
        // view (which holds the loaded bundle + file URLs) can
        // construct the payload and open the standalone window.
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenDetailedStatistics)) { _ in
            guard let bundle = loadedWaveform, !bundle.signalSummary.isEmpty else { return }
            openWindow(
                value: DetailedStatisticsPayload(
                    dayDate: day.date,
                    deviceName: library.card.map { library.displayName(for: $0) },
                    rows: bundle.signalSummary
                )
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenAdvancedCharting)) { _ in
            openWindow(
                value: AdvancedChartingPayload(
                    dayDate: day.date,
                    deviceName: library.card.map { library.displayName(for: $0) },
                    brpURLs: day.files(of: .breath).map(\.url),
                    pldURLs: day.files(of: .physiological).map(\.url),
                    eveURLs: day.files(of: .events).map(\.url)
                )
            )
        }
        #endif
        #if os(iOS)
        // All four day-level sheets follow the same pattern: each
        // view supplies its own NavigationStack + padded
        // `InspectorPaneHeader` on iOS, so the sheet wrappers here
        // only need the detents and drag indicator — no external
        // chrome that would push their headers to different
        // vertical positions.
        .sheet(isPresented: $isShowingNotes) {
            NotesCard(day: day)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingSettings) {
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
            NightSummaryCard(day: day)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingSessions) {
            SessionListSheet(day: day)
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
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenSessions)) { _ in
            isShowingSessions = true
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

    #if os(iOS)
    /// Items shown in the floating action bar. Sleep Analysis is
    /// only present once the on-device intelligence stack is
    /// ready — matching the gating that used to live in the
    /// shared Options menu.
    private var floatingBarItems: [FloatingActionBar.Item] {
        var items: [FloatingActionBar.Item] = []
        if library.intelligence.isReady {
            items.append(.sleepAnalysis)
        }
        items.append(.sleepJournal)
        items.append(.sessions)
        items.append(.therapyDetails)
        return items
    }

    private func handleFloatingBarTap(_ item: FloatingActionBar.Item) {
        switch item {
        case .sleepAnalysis:
            NotificationCenter.default.post(name: .snorecardOpenSleepAnalysis, object: nil)
        case .sleepJournal:
            NotificationCenter.default.post(name: .snorecardOpenDailyNotes, object: nil)
        case .sessions:
            NotificationCenter.default.post(name: .snorecardOpenSessions, object: nil)
        case .therapyDetails:
            NotificationCenter.default.post(name: .snorecardOpenDailySettings, object: nil)
        }
    }
    #endif

    /// Shown while the bundle is still decoding. Pulsing waveform
    /// glyph + spinner makes the wait feel intentional rather than
    /// stuck.
    private var waveformLoadingPlaceholder: some View {
        IssueCallout(
            icon: "waveform.path.ecg",
            iconTint: AnyShapeStyle(.tint),
            pulsing: true,
            title: "Analyzing breath waveforms",
            subtitle: waveformLoadingSubtitle,
            showsProgress: true
        )
    }

    /// Shown when the waveform decoder failed (corrupt EDF, IO
    /// error, etc). Shares the IssueCallout frame with the loading
    /// state — only the symbol and tint swap.
    private func waveformErrorPlaceholder(_ message: String) -> some View {
        IssueCallout(
            icon: "exclamationmark.triangle.fill",
            iconTint: AnyShapeStyle(.red),
            title: "Couldn't load this night",
            subtitle: message
        )
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
                EventDonutView(stats: stats, onTap: explainTap(.ahi))

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
                    if let apneaSeconds = library.displayedTimeInApneaSeconds(stats) {
                        let percent = apneaSeconds / (stats.usageMinutes * 60) * 100
                        StatCard(
                            label: "Time in Apnea",
                            value: formatDurationShort(apneaSeconds),
                            subtitle: String(format: "%.2f%% of usage", percent),
                            tint: apneaColor(percent),
                            onTap: explainTap(.timeInApnea)
                        )
                    }
                    // Apple Watch sleep-stage chips. Mirror the
                    // Trends Deep / REM averages so the per-night
                    // and per-range views read the same. Only on
                    // nights where we have a summary with non-zero
                    // asleep time (otherwise the percentage is
                    // undefined). Reads from the sidecars regardless
                    // of platform — HealthKit is queried only on
                    // iOS, but Mac shows whatever iCloud synced.
                    if let sleep = library.healthSleep.summaryByDate[day.date],
                       sleep.timeAsleep > 0 {
                        let deepPct = sleep.fractionAsleep(in: .deep) * 100
                        let remPct = sleep.fractionAsleep(in: .rem) * 100
                        StatCard(
                            label: "Deep Sleep",
                            value: String(format: "%.0f%%", deepPct),
                            onTap: explainTap(.deepSleepPercent)
                        )
                        StatCard(
                            label: "REM Sleep",
                            value: String(format: "%.0f%%", remPct),
                            onTap: explainTap(.remSleepPercent)
                        )
                    }
                    // IPAP gets its own card only when the device
                    // actually delivers extra inspiratory pressure.
                    // On plain CPAP therapy IPAP equals EPAP, so
                    // the single EPAP card is relabelled
                    // "EPAP/IPAP" to make clear that one value
                    // covers both.
                    let showsDistinctIPAP: Bool = {
                        guard let epap = stats.epap95, let ipap = stats.ipap95 else { return false }
                        return ipap > epap + 0.05
                    }()
                    if let epap = stats.epap95 {
                        StatCard(
                            label: showsDistinctIPAP ? "EPAP (95%)" : "EPAP/IPAP (95%)",
                            value: String(format: "%.1f cmH₂O", epap),
                            onTap: explainTap(.epap95)
                        )
                    }
                    if showsDistinctIPAP, let ipap = stats.ipap95 {
                        StatCard(
                            label: "IPAP (95%)",
                            value: String(format: "%.1f cmH₂O", ipap),
                            onTap: explainTap(.ipap95)
                        )
                    }
                    // Median mask pressure (50th percentile of the
                    // on-therapy waveform, or MaskPress.50 on
                    // AirSense 11 summary) reads as a "typical"
                    // working-pressure complement to the 95%-target
                    // EPAP/IPAP cards above. Only shown when the
                    // standalone IPAP card is hidden so the grid
                    // keeps the same card count whether therapy is
                    // CPAP or bilevel.
                    if !showsDistinctIPAP, let median = stats.pressureMedian {
                        StatCard(
                            label: "Mask Pressure (Median)",
                            value: String(format: "%.1f cmH₂O", median),
                            onTap: explainTap(.maskPressureMedian)
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
                    if let gi = stats.glasgowIndex {
                        let contributor = stats.glasgowBreakdown
                            .flatMap(Self.glasgowTopContributor)
                        StatCard(
                            label: "Glasgow Index",
                            value: String(format: "%.2f", gi),
                            subtitle: contributor.map {
                                String(format: "%.0f%% %@", $0.percent, $0.label)
                            },
                            tint: glasgowColor(gi),
                            onTap: explainTap(.glasgowIndex)
                        )
                    }
                    if let nedMean = stats.nedAnalysisBreakdown?.nedMean {
                        let pct = nedMean * 100
                        StatCard(
                            label: "NED Mean",
                            value: String(format: "%.1f%%", pct),
                            tint: nedMeanColor(pct),
                            onTap: explainTap(.nedMean)
                        )
                    }
                    if let rera = stats.reraIndex {
                        StatCard(
                            label: "RERA Index",
                            value: String(format: "%.1f", rera),
                            tint: reraColor(rera),
                            onTap: explainTap(.reraIndex)
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
                    if let level = SnoreLevel.classify(
                        moderateSeconds: stats.snoreModerateSeconds,
                        loudSeconds: stats.snoreLoudSeconds,
                        usageSeconds: stats.usageMinutes * 60
                    ) {
                        StatCard(
                            label: "Snore",
                            value: level.label,
                            subtitle: SnoreLevel.subtitle(
                                moderateSeconds: stats.snoreModerateSeconds,
                                loudSeconds: stats.snoreLoudSeconds,
                                usageSeconds: stats.usageMinutes * 60
                            ),
                            tint: snoreLevelColor(level),
                            onTap: explainTap(.snore95)
                        )
                    } else if let snore = stats.snore95 {
                        // Fallback for cached days imported before the
                        // band-seconds fields existed — drop them into
                        // the card as the raw 95th-percentile number so
                        // the card isn't blank until the user rebuilds
                        // the cache.
                        StatCard(
                            label: "Snore (95%)",
                            value: String(format: "%.1f", snore),
                            tint: snoreColor(snore),
                            onTap: explainTap(.snore95)
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
                            tint: percent < 0.5 ? .severityGood : library.eventColorPalette.severityHigh,
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
                if let bundle = displayedBundle, !bundle.events.isEmpty {
                    AHIHourlyChart(
                        events: bundle.events,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                // RERA events by hour sits directly under AHI Events
                // by Hour — both are event-rate bar charts, so
                // grouping them lets a glance compare the two
                // event streams without scrolling between them.
                // Empty buckets surface no chart (rather than zero
                // bars) — keeps quiet nights from cluttering the
                // column.
                if let bundle = displayedBundle, !bundle.reraHourBuckets.isEmpty {
                    RERAHourlyChart(
                        buckets: bundle.reraHourBuckets,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                // Glasgow Index and NED Mean follow as a paired
                // breath-quality block — same dayStart anchor as
                // the bars above so the x-axis lines up cleanly.
                // Skipped on nights where no hour scored (too few
                // inspirations across every session).
                if let bundle = displayedBundle, !bundle.glasgowHourSlices.isEmpty {
                    GlasgowHourlyChart(
                        slices: bundle.glasgowHourSlices,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                if let bundle = displayedBundle, !bundle.nedHourSlices.isEmpty {
                    NEDHourlyChart(
                        slices: bundle.nedHourSlices,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                // Sleep-by-hour deep/REM chart. Only renders when
                // both a watch summary and the parsed waveform bundle
                // are present — the bundle supplies the night window
                // (dayStart / duration) and the summary's raw samples
                // are bucketed into the stages. Renders on both
                // platforms — the underlying data comes from sidecars
                // synced via iCloud Drive.
                if let bundle = displayedBundle,
                   let sleep = library.healthSleep.summaryByDate[day.date] {
                    SleepByHourChart(
                        summary: sleep,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                if let bundle = displayedBundle, !bundle.flatLeak.isEmpty {
                    LeakHourlyChart(
                        leak: bundle.flatLeak,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                if let bundle = displayedBundle, !bundle.flatFlowLimitation.isEmpty {
                    FlowLimitHourlyChart(
                        flowLimit: bundle.flatFlowLimitation,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                if let bundle = displayedBundle, !bundle.flatPressure.isEmpty {
                    PressureHourlyChart(
                        pressure: bundle.flatPressure,
                        dayStart: bundle.dayStart,
                        totalDuration: bundle.totalDuration
                    )
                }
                if let bundle = displayedBundle, !bundle.flatTidalVolume.isEmpty {
                    TidalVolumeHourlyChart(
                        tidalVolume: bundle.flatTidalVolume,
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
            // Two paths land here: (1) the device recorded files but
            // no usable summary (e.g. STR.edf hadn't rolled the night
            // up yet at import time), and (2) the user has manually
            // excluded every session, zeroing the day's usage. Same
            // empty surface either way, but the wording owns up to
            // the user-driven case so the screen doesn't pretend
            // their machine misbehaved.
            if allSessionsManuallyExcluded {
                IssueCallout(
                    icon: "eye.slash",
                    iconTint: AnyShapeStyle(.secondary),
                    title: "All sessions excluded",
                    subtitle: "You've turned every session for this night off. Re-include one from Therapy Sessions to see this night's totals."
                )
            } else {
                IssueCallout(
                    icon: "moon.zzz",
                    iconTint: AnyShapeStyle(.secondary),
                    title: "No summary data",
                    subtitle: "This device didn't record a usable summary for this night."
                )
            }
        }
    }

    /// True when this day's BRP session keys are all in the user's
    /// manual-exclusion set. Distinguishes the "user hid everything"
    /// case from a genuinely empty night so the header message can
    /// own up to the cause. Returns false when the day has no BRP
    /// keys at all, since we can't claim the user excluded what was
    /// never there.
    private var allSessionsManuallyExcluded: Bool {
        let brpKeys = Set(day.files(of: .breath).compactMap(\.sessionKey))
        guard !brpKeys.isEmpty else { return false }
        return brpKeys.isSubset(of: library.excludedSessionKeys)
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
        case .reraIndex:        return "RERA Index"
        case .nedMean:          return "NED Mean"
        case .epap95:           return "EPAP (95%)"
        case .ipap95:           return "IPAP (95%)"
        case .maskPressureMedian: return "Mask Pressure (Median)"
        case .leak95:           return "Leak (95%)"
        case .largeLeak:        return "Large Leak"
        case .tidalVolume:      return "Tidal Volume"
        case .snore95:          return "Snore (95%)"
        case .usage:            return "Usage"
        case .timeInApnea:      return "Time in Apnea"
        case .flowLimit:        return "Flow Limit (95%)"
        case .deepSleepPercent: return "Deep Sleep"
        case .remSleepPercent:  return "REM Sleep"
        // Trends-only metrics fall back to their enum label —
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
        case .ahi:          return String(format: "%.2f", library.displayedAHI(stats))
        case .glasgowIndex:
            return stats.glasgowIndex.map { String(format: "%.2f", $0) } ?? "—"
        case .reraIndex:
            return stats.reraIndex.map { String(format: "%.1f", $0) } ?? "—"
        case .nedMean:
            return stats.nedAnalysisBreakdown.map { String(format: "%.1f%%", $0.nedMean * 100) } ?? "—"
        case .epap95:
            return stats.epap95.map { String(format: "%.1f cmH₂O", $0) } ?? "—"
        case .ipap95:
            return stats.ipap95.map { String(format: "%.1f cmH₂O", $0) } ?? "—"
        case .maskPressureMedian:
            return stats.pressureMedian.map { String(format: "%.1f cmH₂O", $0) } ?? "—"
        case .leak95:
            return stats.leak95LPerMin.map { String(format: "%.0f L/min", $0) } ?? "—"
        case .largeLeak:
            guard let seconds = stats.largeLeakSeconds, stats.usageMinutes > 0
            else { return "—" }
            let pct = seconds / (stats.usageMinutes * 60) * 100
            return String(format: "%.0f%%", pct)
        case .tidalVolume:
            return stats.tidalVolume50.map { String(format: "%.0f mL", $0 * 1000) } ?? "—"
        case .snore95:
            return stats.snore95.map { String(format: "%.1f", $0) } ?? "—"
        case .usage:
            return formatHours(stats.usageHours)
        case .timeInApnea:
            guard let seconds = library.displayedTimeInApneaSeconds(stats),
                  stats.usageMinutes > 0
            else { return "—" }
            let pct = seconds / (stats.usageMinutes * 60) * 100
            return String(format: "%.2f%% of usage", pct)
        case .flowLimit:
            return stats.flowLimit95.map { String(format: "%.2f", $0) } ?? "—"
        case .deepSleepPercent:
            guard let sleep = library.healthSleep.summaryByDate[day.date],
                  sleep.timeAsleep > 0 else { return "—" }
            return String(format: "%.0f%%", sleep.fractionAsleep(in: .deep) * 100)
        case .remSleepPercent:
            guard let sleep = library.healthSleep.summaryByDate[day.date],
                  sleep.timeAsleep > 0 else { return "—" }
            return String(format: "%.0f%%", sleep.fractionAsleep(in: .rem) * 100)
        // Trends-only metrics have no per-day value — the sheet
        // path on DayDetailView never hits these cases, but
        // exhaustive switching still requires them.
        case .compliance, .daysWithData, .sessionsPerNight:
            return "—"
        }
    }

    /// Dominant Glasgow sub-index in a single-night breakdown and its
    /// share of the total score. Surfaced as the Glasgow card's
    /// subtitle ("47% top-heavy") so the headline number is paired
    /// with the breath characteristic driving it. Returns nil when
    /// the total is zero or every sub-index is empty.
    static func glasgowTopContributor(
        _ breakdown: GlasgowIndex.Breakdown
    ) -> (label: String, percent: Double)? {
        let total = breakdown.total
        guard total > 0 else { return nil }
        // Labels match the wording the Trends view uses.
        let fields: [(String, Double)] = [
            ("flat-top", breakdown.flatTop),
            ("top-heavy", breakdown.topHeavy),
            ("skewed", breakdown.skew),
            ("spiky", breakdown.spike),
            ("multi-peak", breakdown.multiPeak),
            ("no pause", breakdown.noPause),
            ("fast rate", breakdown.inspirRate),
            ("missed exhale", breakdown.multiBreath),
            ("variable amplitude", breakdown.ampVar)
        ]
        guard let top = fields.max(by: { $0.1 < $1.1 }), top.1 > 0 else {
            return nil
        }
        return (top.0, (top.1 / total) * 100)
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
        // `stats.maskEvents` reflects the BRP files that survived
        // the aggregate's filters (manual exclusions + the < 2 min
        // brief-session rule), so this subtitle agrees with the
        // Usage value above. Falls back to raw file count only
        // when the day has no stats yet (mid-load placeholder).
        let count = day.stats?.maskEvents ?? day.files(of: .breath).count
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

    // MARK: - Stat-card severity tints
    //
    // Clinical thresholds stay fixed; amber/red cues route through
    // `library.eventColorPalette` so card backgrounds adapt to the
    // active theme. `.severityGood` keeps the global neutral colour
    // because StatCard treats it as the implicit default and doesn't
    // tint the plate at all — green never actually renders.

    private func ahiColor(_ ahi: Double) -> Color {
        switch ahi {
        case ..<2: return .severityGood
        case ..<5: return library.eventColorPalette.severityLow
        default:   return library.eventColorPalette.severityHigh
        }
    }

    /// Leak-severity palette — green under 5 L/min, amber 5–9, red ≥ 10.
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

    /// Glasgow Index palette — neutral under 2, amber 2–3, red ≥ 3.
    private func glasgowColor(_ value: Double) -> Color {
        switch value {
        case ..<2.0: return .severityGood
        case ..<3.0: return library.eventColorPalette.severityLow
        default:     return library.eventColorPalette.severityHigh
        }
    }

    /// RERA events / hour palette — mirrors AHI bands because RERA
    /// rolls into the same RDI (= AHI + RERA) scoring tradition:
    /// ≤ 5/hr controlled, 5–15/hr mild, ≥ 15/hr elevated. The
    /// thresholds aren't clinical RERA cutoffs — none are
    /// standardised — but they keep this card visually consistent
    /// with the AHI card right above it.
    private func reraColor(_ value: Double) -> Color {
        switch value {
        case ..<5:  return .severityGood
        case ..<15: return library.eventColorPalette.severityLow
        default:    return library.eventColorPalette.severityHigh
        }
    }

    /// NED Mean palette (percent units). The per-breath FL marker
    /// fires at `NED > 20%`, but a *nightly average* of 20 still
    /// sits below where the night reads as flow-limited overall —
    /// the band thresholds here are wider than the per-breath cut
    /// to leave headroom for breaths that spike high without
    /// dragging the whole night red. < 15% reads as well within
    /// normal range; 15–25% is elevated; ≥ 25% the typical breath
    /// is itself flow-limited.
    private func nedMeanColor(_ pct: Double) -> Color {
        switch pct {
        case ..<15: return .severityGood
        case ..<25: return library.eventColorPalette.severityLow
        default:    return library.eventColorPalette.severityHigh
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

    /// Snore palette (95th-percentile index on ResMed's 0–5 scale) —
    /// under 1 is quiet, 1–3 is mild / intermittent, ≥3 is loud or
    /// sustained. Matches the norm boundaries given to the explain
    /// sheet so the card colour agrees with the AI description.
    /// Still used as a fallback for cached days imported before the
    /// band-seconds fields existed.
    private func snoreColor(_ index: Double) -> Color {
        switch index {
        case ..<1: return .severityGood
        case ..<3: return library.eventColorPalette.severityLow
        default:   return library.eventColorPalette.severityHigh
        }
    }

    /// Tint for the qualitative snore chip — mirrors the event-
    /// severity palette so Quiet / Mild sit in the calm range and
    /// Moderate / Loud escalate.
    private func snoreLevelColor(_ level: SnoreLevel) -> Color {
        switch level {
        case .quiet:    return .severityGood
        case .mild:     return library.eventColorPalette.severityLow
        case .moderate: return library.eventColorPalette.severityLow
        case .loud:     return library.eventColorPalette.severityHigh
        }
    }

    /// Tidal-volume palette (median mL) — two-sided: green in the 420–
    /// 600 mL sweet spot (roughly 7 mL/kg IBW for an average adult),
    /// amber on either side of the healthy window, red at the extremes.
    private func tidalVolumeColor(_ mL: Double) -> Color {
        switch mL {
        case ..<350: return library.eventColorPalette.severityHigh
        case ..<420: return library.eventColorPalette.severityLow
        case ...600: return .severityGood
        case ...700: return library.eventColorPalette.severityLow
        default:     return library.eventColorPalette.severityHigh
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
