import SwiftUI
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
                stagesBar(for: summary)
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

    /// Horizontal bar made of `Capsule` segments weighted by stage
    /// seconds. Falls back to a flat track when the night has no
    /// asleep time so the card doesn't render an empty box.
    private func stagesBar(for summary: NightlySleepSummary) -> some View {
        let total = summary.timeAsleep + summary.awakeSeconds
        return GeometryReader { geo in
            HStack(spacing: 2) {
                if total > 0 {
                    segment(width: width(summary.deepSeconds, total: total, fullWidth: geo.size.width), color: .indigo)
                    segment(width: width(summary.coreSeconds, total: total, fullWidth: geo.size.width), color: .blue)
                    segment(width: width(summary.remSeconds, total: total, fullWidth: geo.size.width), color: .teal)
                    segment(width: width(summary.unspecifiedSeconds, total: total, fullWidth: geo.size.width), color: .gray.opacity(0.6))
                    segment(width: width(summary.awakeSeconds, total: total, fullWidth: geo.size.width), color: .orange)
                } else {
                    Capsule().fill(Color.secondary.opacity(0.25))
                }
            }
        }
        .frame(height: 14)
    }

    private func width(_ value: TimeInterval, total: TimeInterval, fullWidth: CGFloat) -> CGFloat {
        guard total > 0, value > 0 else { return 0 }
        return CGFloat(value / total) * fullWidth
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: max(0, width), height: 14)
            .opacity(width > 0 ? 1 : 0)
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
