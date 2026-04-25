import SwiftUI
import Charts
import SnorecardKit

/// Per-night sleep-stages summary card. Renders next to the existing
/// `StatCard` grid on `DayDetailView` whenever a `NightlySleepSummary`
/// exists for that night — when it doesn't, the call site simply
/// omits the card so the day grid doesn't carry an empty placeholder.
/// The Connect / Re-sync entry points live in Settings.
struct AppleWatchSleepCard: View {
    @Environment(Library.self) private var library
    let summary: NightlySleepSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sleep Stages")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            hypnogram(for: summary)
            if let start = summary.inBedStart, let end = summary.inBedEnd {
                Text("In bed \(timeFormatter.string(from: start)) – \(timeFormatter.string(from: end))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            stageLegend(for: summary)
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
    /// transitions left → right. `inBed` envelope records are
    /// filtered out (they'd paint over the real stages); `awake`
    /// records are also filtered so the strip only shows time the
    /// user was actually asleep — gaps between rectangles read as
    /// the awake intervals without needing a colour for them.
    @ViewBuilder
    private func hypnogram(for summary: NightlySleepSummary) -> some View {
        let stages = summary.samples
            .filter { $0.stage != .inBed && $0.stage != .awake }
            .sorted { $0.start < $1.start }
        if stages.isEmpty {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 18)
                .overlay(
                    Text("No stage data")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                )
        } else {
            Chart {
                ForEach(stages) { sample in
                    RectangleMark(
                        xStart: .value("Start", sample.start),
                        xEnd: .value("End", sample.end),
                        yStart: .value("Y", 0),
                        yEnd: .value("Y", 1)
                    )
                    .foregroundStyle(color(for: sample.stage))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...1)
            .frame(height: 36)
        }
    }

    private func color(for stage: SleepStageSample.Stage) -> Color {
        let palette = library.eventColorPalette
        switch stage {
        case .deep: return palette.deepSleep
        case .core, .asleepUnspecified: return palette.coreSleep
        case .rem: return palette.remSleep
        case .awake: return .orange
        case .inBed: return .gray
        }
    }

    private func stageLegend(for summary: NightlySleepSummary) -> some View {
        let palette = library.eventColorPalette
        return HStack(spacing: 12) {
            legendItem(color: palette.deepSleep, label: "Deep", value: formatDuration(summary.deepSeconds))
            legendItem(color: palette.coreSleep, label: "Core", value: formatDuration(summary.coreSeconds))
            legendItem(color: palette.remSleep, label: "REM", value: formatDuration(summary.remSeconds))
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
