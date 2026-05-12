import SwiftUI
import os.log
import SnorecardKit

private let advancedChartingLog = Logger(subsystem: "com.vmstan.Snorecard", category: "AdvancedCharting")

/// Payload threaded through SwiftUI's `openWindow(value:)` (macOS)
/// or a sheet (iOS) so the Advanced Charting surface can load its
/// waveform bundle from disk without a back-reference to
/// `DayDetailView`. Hashable + Codable per SwiftUI's window
/// restoration requirements.
struct AdvancedChartingPayload: Hashable, Codable, Identifiable {
    let dayDate: Date
    let deviceName: String?
    let brpURLs: [URL]
    let pldURLs: [URL]
    let eveURLs: [URL]

    var id: Date { dayDate }
}

/// Trigger-only "Advanced Charting" button. Mirrors
/// `DailySignalSummaryTable` — macOS opens a standalone window
/// keyed on the payload's day date (so opening the same night
/// twice reuses the window instead of stacking duplicates),
/// while iOS pops a sheet. Renders nothing when the day has no
/// breath waveform files.
struct AdvancedChartingButton: View {
    let payload: AdvancedChartingPayload

    @Environment(\.openWindow) private var openWindow
    @State private var isShowingSheet = false

    var body: some View {
        if !payload.brpURLs.isEmpty {
            Button {
                #if os(macOS)
                openWindow(value: payload)
                #else
                isShowingSheet = true
                #endif
            } label: {
                DayActionButtonLabel(
                    title: "Detailed Waveforms",
                    subtitle: "High-resolution breathing and pressure traces",
                    systemImage: "waveform",
                    tint: .chartOrange
                )
            }
            .buttonStyle(DayActionButtonStyle())
            #if os(iOS)
            .sheet(isPresented: $isShowingSheet) {
                NavigationStack {
                    AdvancedChartingView(payload: payload)
                        .navigationTitle("Detailed Waveforms")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDragIndicator(.visible)
                // iPad's default sheet sizing is the compact centered
                // form sheet, which cramps the waveform + timeline
                // stack. `.page` sizing fills the bulk of the window
                // so the charts breathe at a sensible width. On
                // iPhone this is a no-op — sheets there always fill
                // the screen regardless of sizing.
                .presentationSizing(.page)
            }
            #endif
        }
    }
}

/// High-resolution waveform + session-timeline surface, hosted in
/// its own macOS window or an iOS sheet so the detail view stays
/// focused on the summary metrics + hourly charts. Loads its
/// bundle from the payload's file URLs on appear; reloads when
/// the payload changes.
struct AdvancedChartingView: View {
    let payload: AdvancedChartingPayload

    @Environment(Library.self) private var library
    @State private var bundle: WaveformBundle?
    @State private var loadError: String?

    /// Apple Watch sleep summary for this payload's night, when
    /// the coordinator has one in memory. Pulled fresh on each
    /// render so toggling the feature off in another window
    /// removes the timeline tint here too. macOS reads sidecars
    /// only — same source as iOS, just no HealthKit fetch.
    private var sleepSummary: NightlySleepSummary? {
        let calendar = Calendar.current
        let key = calendar.startOfDay(for: payload.dayDate)
        return library.healthSleep.summaryByDate[key]
    }

    var body: some View {
        content
            #if os(macOS)
            // Populates the macOS title bar so the floating window
            // reads as "Detailed Waveforms — <date>" instead of
            // inheriting the generic app name. Matches the
            // treatment on `DetailedStatisticsView`.
            .navigationTitle("Detailed Waveforms")
            .navigationSubtitle(navigationSubtitle)
            #endif
            .task(id: payload.id) {
                await loadBundle()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let bundle {
            ScrollView {
                WaveformSection(
                    bundle: bundle.filteringInactiveSessions(inactiveSessionIDs(in: bundle)),
                    sleepSummary: sleepSummary
                )
                .padding(20)
            }
        } else if let loadError {
            ContentUnavailableView {
                Label("Couldn't Decode Sessions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else {
            // Share `DayDetailView`'s loading placeholder via
            // `IssueCallout` so the two surfaces read as one set —
            // same glyph, headline, pulse, spinner.
            IssueCallout(
                icon: "waveform.path.ecg",
                iconTint: AnyShapeStyle(.tint),
                pulsing: true,
                title: "Decoding sessions…",
                showsProgress: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    private var navigationSubtitle: String {
        let date = payload.dayDate.formatted(
            .dateTime.weekday(.wide).month(.wide).day()
        )
        if let device = payload.deviceName, !device.isEmpty {
            return "\(device) · \(date)"
        }
        return date
    }

    /// Same `briefSession + excludedSessionKeys` mapping the daily
    /// view does, applied here so the standalone waveform window
    /// drops auto-excluded and manually-excluded sessions and
    /// recalibrates its X-axis to the kept range.
    private func inactiveSessionIDs(in bundle: WaveformBundle) -> Set<UUID> {
        let excludedKeys = library.excludedSessionKeys
        var ids: Set<UUID> = []
        for session in bundle.sessions {
            if session.duration < 120 {
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

    private func loadBundle() async {
        bundle = nil
        loadError = nil

        advancedChartingLog.info("load start day=\(payload.dayDate, privacy: .public) brp=\(payload.brpURLs.count) pld=\(payload.pldURLs.count) eve=\(payload.eveURLs.count)")

        let brpURLs = payload.brpURLs
        let pldURLs = payload.pldURLs
        let eveURLs = payload.eveURLs

        do {
            // Detached so the decode runs on a background queue —
            // the bundle work is CPU heavy enough to stutter the
            // initial window layout if run on the main actor.
            let loaded = try await Task.detached(priority: .userInitiated) {
                try WaveformBundle.load(
                    brpFiles: brpURLs,
                    pldFiles: pldURLs,
                    eveFiles: eveURLs
                )
            }.value
            advancedChartingLog.info("load done sessions=\(loaded.sessions.count) events=\(loaded.events.count)")
            bundle = loaded
        } catch {
            advancedChartingLog.error("load failed: \(String(describing: error), privacy: .public)")
            loadError = String(describing: error)
        }
    }
}
