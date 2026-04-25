import SwiftUI
import Charts
import SnorecardKit

/// Range-scoped Apple Watch sleep-stage aggregates, plus a stacked-area
/// chart of nightly stage minutes across the range. Hidden by the
/// caller when zero summaries fall in the range — this view assumes a
/// non-empty list at render.
struct SleepStageTrendsSection: View {
    /// Summaries that fell inside the trends range, oldest first.
    let summaries: [NightlySleepSummary]

    private struct StackPoint: Identifiable {
        var id: String { "\(date.timeIntervalSinceReferenceDate)|\(stage)" }
        let date: Date
        let stage: String
        let minutes: Double
    }

    private var avgAsleepHours: Double {
        guard !summaries.isEmpty else { return 0 }
        let total = summaries.reduce(0) { $0 + $1.timeAsleep }
        return total / Double(summaries.count) / 3600
    }

    private var avgDeepPercent: Double {
        guard !summaries.isEmpty else { return 0 }
        let frac = summaries.reduce(0) { $0 + $1.fractionAsleep(in: .deep) }
        return (frac / Double(summaries.count)) * 100
    }

    private var avgRemPercent: Double {
        guard !summaries.isEmpty else { return 0 }
        let frac = summaries.reduce(0) { $0 + $1.fractionAsleep(in: .rem) }
        return (frac / Double(summaries.count)) * 100
    }

    private var stackPoints: [StackPoint] {
        summaries.flatMap { summary -> [StackPoint] in
            [
                StackPoint(date: summary.nightDate, stage: "Deep", minutes: summary.deepSeconds / 60),
                StackPoint(date: summary.nightDate, stage: "Core", minutes: summary.coreSeconds / 60),
                StackPoint(date: summary.nightDate, stage: "REM", minutes: summary.remSeconds / 60)
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Watch Sleep")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                StatCard(
                    label: "Avg Sleep",
                    value: String(format: "%.1f h", avgAsleepHours),
                    subtitle: "across \(summaries.count) night\(summaries.count == 1 ? "" : "s")"
                )
                StatCard(
                    label: "Avg Deep",
                    value: String(format: "%.0f%%", avgDeepPercent),
                    subtitle: "of asleep time"
                )
                StatCard(
                    label: "Avg REM",
                    value: String(format: "%.0f%%", avgRemPercent),
                    subtitle: "of asleep time"
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Stage minutes per night")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Chart(stackPoints) { point in
                    BarMark(
                        x: .value("Night", point.date, unit: .day),
                        y: .value("Minutes", point.minutes)
                    )
                    .foregroundStyle(by: .value("Stage", point.stage))
                }
                .chartForegroundStyleScale([
                    "Deep": Color.indigo,
                    "Core": Color.blue,
                    "REM": Color.teal
                ])
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let m = value.as(Double.self) {
                                Text("\(Int(m))m").font(.caption2.monospacedDigit())
                            }
                        }
                    }
                }
                .frame(minHeight: 200)
            }
            .padding(14)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
    }
}
