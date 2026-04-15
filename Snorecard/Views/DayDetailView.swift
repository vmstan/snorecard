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
                    WaveformSection(bundle: bundle)
                } else {
                    ProgressView("Decoding sessions…")
                        .progressViewStyle(.circular)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(20)
        }
        .navigationTitle(Text(day.date, format: .dateTime.weekday(.wide).day().month(.wide).year()))
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
                        subtitle: sessionCountLabel
                    )
                    StatCard(
                        label: "Events",
                        value: "\(Int((stats.ahi * stats.usageHours).rounded()))"
                    )

                    if let epap = stats.epap95 {
                        let support = stats.ipap95.map { max(0, $0 - epap) }
                        StatCard(
                            label: "Pressure (95%)",
                            value: String(format: "%.1f cmH₂O", epap),
                            subtitle: support.map { String(format: "Support %.1f", $0) }
                        )
                    }
                    if let leak = stats.leak95LPerMin {
                        StatCard(
                            label: "Leak (95%)",
                            value: String(format: "%.0f L/min", leak),
                            tint: leak > 24 ? .orange : .primary
                        )
                    }
                    if let apneaSeconds = stats.timeInApneaSeconds {
                        StatCard(
                            label: "Time in Apnea",
                            value: formatDurationShort(apneaSeconds),
                            subtitle: "\(Int((apneaSeconds / (stats.usageMinutes * 60) * 100).rounded()))% of usage"
                        )
                    }
                    if let largeLeak = stats.largeLeakSeconds {
                        let usageSeconds = stats.usageMinutes * 60
                        let percent = usageSeconds > 0 ? (largeLeak / usageSeconds * 100) : 0
                        StatCard(
                            label: "Large Leak",
                            value: String(format: "%.0f%%", percent),
                            subtitle: formatDurationShort(largeLeak),
                            tint: largeLeak > 300 ? .orange : .primary
                        )
                    }
                    if let tv = stats.tidalVolume50 {
                        StatCard(label: "Tidal Volume (Median)", value: String(format: "%.2f L", tv))
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

    private func ahiColor(_ ahi: Double) -> Color {
        switch ahi {
        case ..<5: .green
        case ..<15: .yellow
        case ..<30: .orange
        default: .red
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
