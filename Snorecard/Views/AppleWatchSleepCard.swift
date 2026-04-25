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
            HStack(alignment: .firstTextBaseline) {
                Text("Apple Watch Sleep")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if let summary {
                    Text(formatDuration(summary.timeAsleep))
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
            }

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

    /// Hypnogram-style timeline matching how the iOS Health app
    /// renders a night: four stage rows (Awake on top, REM, Core,
    /// Deep on bottom) with one rectangle per `SleepStageSample` at
    /// its actual wall-clock start/end. `inBed` records are filtered
    /// out — Apple writes them as overlapping envelope rows that
    /// would obscure the real stages.
    private func hypnogram(for summary: NightlySleepSummary) -> some View {
        let stages = summary.samples
            .filter { $0.stage != .inBed }
            .sorted { $0.start < $1.start }
        guard !stages.isEmpty else {
            return AnyView(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 14)
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
                        yStart: .value("Stage", Self.stageRow(for: sample.stage)),
                        yEnd: .value("Stage", Self.stageRow(for: sample.stage) + 0.85)
                    )
                    .foregroundStyle(Self.color(for: sample.stage))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.caption2.monospacedDigit())
                }
            }
            .chartYAxis {
                // Mid-row tick positions so the label centres in
                // each stage band rather than sitting on its edge.
                AxisMarks(position: .leading, values: [0.4, 1.4, 2.4, 3.4]) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self),
                           let label = Self.label(forRow: v - 0.4) {
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...4)
            .frame(height: 100)
        )
    }

    /// Stage → row index. Top→bottom in the rendered chart is
    /// Awake (3) → REM (2) → Core (1) → Deep (0), matching the
    /// Health app's visual ordering. `asleepUnspecified` is
    /// folded into Core because it represents legacy watchOS
    /// pre-iOS-16 records that didn't differentiate stages.
    private static func stageRow(for stage: SleepStageSample.Stage) -> Double {
        switch stage {
        case .deep: return 0
        case .core, .asleepUnspecified: return 1
        case .rem: return 2
        case .awake: return 3
        case .inBed: return -1   // never rendered — filtered out
        }
    }

    private static func label(forRow row: Double) -> String? {
        switch Int(row.rounded()) {
        case 0: return "Deep"
        case 1: return "Core"
        case 2: return "REM"
        case 3: return "Awake"
        default: return nil
        }
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
