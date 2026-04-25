import SwiftUI
import Charts
import SnorecardKit

/// Per-night sleep-stage summary card. Renders next to the existing
/// `StatCard` grid on `DayDetailView`. Three render paths:
///   1. Summary present → stage breakdown bar + in-bed window.
///   2. Toggle off, prompt not yet shown / declined → "Connect" CTA.
///   3. Toggle on but no data for this night → quiet empty state.
///
/// The card always renders its own plate so the surrounding grid
/// doesn't reflow when the user enables the feature.
struct AppleWatchSleepCard: View {
    @Environment(Library.self) private var library
    let summary: NightlySleepSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Watch Sleep")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let summary {
                hypnogram(for: summary)
                if let start = summary.inBedStart, let end = summary.inBedEnd {
                    Text("In bed \(timeFormatter.string(from: start)) – \(timeFormatter.string(from: end))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                stageLegend(for: summary)
            } else if !library.appleWatchSleepEnabled {
                connectPrompt
            } else {
                noDataPlaceholder
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    /// Single-row chronological timeline of sleep stages — one
    /// `RectangleMark` per `SleepStageSample`, all stacked on the
    /// same row and color-coded by stage. The time axis along the
    /// bottom carries the chronology so the user reads stage
    /// transitions left → right. `inBed` records are filtered out
    /// so Apple's overlapping envelope rows don't paint over the
    /// real stages.
    private func hypnogram(for summary: NightlySleepSummary) -> some View {
        let stages = summary.samples
            .filter { $0.stage != .inBed }
            .sorted { $0.start < $1.start }
        guard !stages.isEmpty else {
            return AnyView(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 18)
                    .overlay(
                        Text("No stage data")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    )
            )
        }
        return AnyView(
            Chart {
                ForEach(stages) { sample in
                    RectangleMark(
                        xStart: .value("Start", sample.start),
                        xEnd: .value("End", sample.end),
                        yStart: .value("Y", 0),
                        yEnd: .value("Y", 1)
                    )
                    .foregroundStyle(Self.color(for: sample.stage))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: Self.xAxisDesiredCount)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(Self.shortClockLabel(for: date))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...1)
            .frame(height: 36)
        )
    }

    /// `12a` / `11p` style label — same convention as
    /// `AHIHourlyChart` so all the day-view charts use the same
    /// short clock vocabulary, and avoids the long "11:30 PM"
    /// rendering of `.dateTime.hour().minute()` that crowded the
    /// axis on iPhone.
    private static func shortClockLabel(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 0:        return "12a"
        case 1..<12:   return "\(hour)a"
        case 12:       return "12p"
        default:       return "\(hour - 12)p"
        }
    }

    /// Fewer marks on iPhone so the labels don't collide. macOS has
    /// plenty of horizontal room.
    private static var xAxisDesiredCount: Int {
        #if os(iOS)
        return 5
        #else
        return 8
        #endif
    }

    private static func color(for stage: SleepStageSample.Stage) -> Color {
        switch stage {
        case .deep: return .indigo
        case .core, .asleepUnspecified: return .blue
        case .rem: return .teal
        case .awake: return .orange
        case .inBed: return .gray
        }
    }

    private func stageLegend(for summary: NightlySleepSummary) -> some View {
        HStack(spacing: 12) {
            legendItem(color: .indigo, label: "Deep", value: formatDuration(summary.deepSeconds))
            legendItem(color: .blue, label: "Core", value: formatDuration(summary.coreSeconds))
            legendItem(color: .teal, label: "REM", value: formatDuration(summary.remSeconds))
            if summary.awakeSeconds > 0 {
                legendItem(color: .orange, label: "Awake", value: formatDuration(summary.awakeSeconds))
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(value)")
        }
    }

    private var connectPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect Apple Watch sleep")
                .font(.subheadline.weight(.semibold))
            Text("Show deep, core and REM stages alongside this night's CPAP data.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                library.acceptHealthKitFirstRunPrompt()
            } label: {
                Label("Connect", systemImage: "applewatch")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }

    private var noDataPlaceholder: some View {
        Text("No Apple Watch sleep data for this night.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }

    /// `Hh Mm` total — matches the format used elsewhere in the app
    /// for usage-time displays.
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var timeFormatter: DateFormatter {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return fmt
    }
}
