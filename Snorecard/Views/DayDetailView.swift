import SwiftUI
import Charts
import SnorecardKit
import os.log

private let waveformLog = Logger(subsystem: "com.vmstan.Snorecard", category: "Waveform")

struct DayDetailView: View {
    let day: ResMedDay
    @State private var loadedWaveform: WaveformBundle?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let error = loadError {
                    Text(error)
                        .foregroundStyle(.red)
                } else if let bundle = loadedWaveform {
                    Divider()
                        .padding(.vertical, 4)
                    WaveformSection(bundle: bundle)
                } else {
                    ProgressView("Decoding sessions…")
                        .progressViewStyle(.circular)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(20)
        }
        .navigationTitle(navigationTitleText)
        .task(id: day.id) {
            await loadAllSessions()
        }
    }

    @ViewBuilder
    private var header: some View {
        if let stats = day.stats, stats.hasUsage {
            VStack(alignment: .leading, spacing: 12) {
                EventDonutView(
                    stats: stats,
                    hourlyEvents: loadedWaveform?.events ?? [],
                    hourlyDayStart: loadedWaveform?.dayStart
                )

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    StatCard(
                        label: "Usage",
                        value: formatHours(stats.usageHours),
                        subtitle: sessionCountLabel,
                        tint: usageColor(stats.usageHours)
                    )
                    if let apneaSeconds = stats.timeInApneaSeconds {
                        let percent = apneaSeconds / (stats.usageMinutes * 60) * 100
                        StatCard(
                            label: "Time in Apnea",
                            value: formatDurationShort(apneaSeconds),
                            subtitle: String(format: "%.2f%% of usage", percent),
                            tint: apneaColor(percent)
                        )
                    }
                    if let gi = stats.glasgowIndex {
                        StatCard(
                            label: "Glasgow Index",
                            value: String(format: "%.2f", gi),
                            tint: glasgowColor(gi)
                        )
                    }

                    if let epap = stats.epap95 {
                        let support = stats.ipap95.map { max(0, $0 - epap) }
                        StatCard(
                            label: "Pressure (95%)",
                            value: String(format: "%.1f cmH₂O", epap),
                            subtitle: support.map { String(format: "Support %.1f", $0) }
                        )
                    }
                    if let fl = stats.flowLimit95 {
                        StatCard(
                            label: "Flow Limit (95%)",
                            value: String(format: "%.2f", fl),
                            tint: flowLimitColor(fl)
                        )
                    }
                    if let leak = stats.leak95LPerMin {
                        StatCard(
                            label: "Leak (95%)",
                            value: String(format: "%.0f L/min", leak),
                            tint: leakColor(leak)
                        )
                    }
                    if let largeLeak = stats.largeLeakSeconds {
                        let usageSeconds = stats.usageMinutes * 60
                        let percent = usageSeconds > 0 ? (largeLeak / usageSeconds * 100) : 0
                        StatCard(
                            label: "Large Leak",
                            value: String(format: "%.0f%%", percent),
                            subtitle: formatDurationShort(largeLeak),
                            tint: percent < 0.5 ? .severityGood : .severityHigh
                        )
                    }
                    if let tv = stats.tidalVolume50 {
                        let mL = tv * 1000
                        StatCard(
                            label: "Tidal Volume (Median)",
                            value: String(format: "%.0f mL", mL),
                            tint: tidalVolumeColor(mL)
                        )
                    }
                }
            }
        } else if !day.files.isEmpty {
            Text("No summary data available for this day.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
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
        case ..<5: .severityGood
        case ..<15: .severityLow
        case ..<30: .severityMedium
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
