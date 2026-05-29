import SwiftUI
import Charts
import SnorecardKit

/// Line chart of Apple Watch deep- and REM-sleep minutes bucketed by
/// clock hour. Hour bucketing matches `AHIHourlyChart` so the x-axis
/// lines up with every other hourly chart on the day view.
///
/// Awake / in-bed-only and core stages are deliberately excluded —
/// the chart's job is to surface the restorative architecture (deep
/// and REM) across the night, not to plot every category sample.
struct SleepByHourChart: View {
    @Environment(Library.self) private var library
    let summary: NightlySleepSummary
    let dayStart: Date
    /// Total night duration in seconds. Drives the bucket range so
    /// every hourly chart on the day view shares the same x axis,
    /// matching `AHIHourlyChart`.
    let totalDuration: TimeInterval

    private struct HourBucket: Identifiable {
        var id: Int { startHour }
        let startHour: Int
        let clockLabel: String
        /// Minutes of each plotted stage that fall inside this hour.
        let deepMinutes: Double
        let remMinutes: Double
    }

    private var buckets: [HourBucket] {
        let calendar = Calendar.current
        // Snap the first bucket to the hour boundary at or before
        // dayStart. `dateInterval(of: .hour, for:)` is the right
        // primitive for "snap-down to hour"; chaining
        // `Calendar.date(bySetting:)` rolls forward to the next
        // matching value (e.g. 23:38:39 ends up at the next
        // midnight, not at 23:00:00) which silently dropped the
        // partial first hour from every hourly chart.
        let anchor = calendar.dateInterval(of: .hour, for: dayStart)?.start ?? dayStart

        // `totalDuration` is measured from `dayStart`, which sits
        // partway through the first hour. The hour grid is anchored
        // earlier (at the hour boundary at-or-before `dayStart`), so
        // we widen the span by `anchorOffset` to make sure the last
        // hour gets its own bucket instead of being clipped past the
        // chart edge.
        let anchorOffset = dayStart.timeIntervalSince(anchor)
        let anchorToEnd = totalDuration + anchorOffset
        let lastHour = Int((max(anchorToEnd, 1) / 3600).rounded(.up)) - 1
        guard lastHour >= 0 else { return [] }

        var out: [HourBucket] = []
        out.reserveCapacity(lastHour + 1)
        for hour in 0...lastHour {
            let bucketStart = anchor.addingTimeInterval(TimeInterval(hour) * 3600)
            let bucketEnd = bucketStart.addingTimeInterval(3600)

            let deep = stageMinutes(in: bucketStart...bucketEnd, stage: .deep)
            let rem = stageMinutes(in: bucketStart...bucketEnd, stage: .rem)

            out.append(
                HourBucket(
                    startHour: hour,
                    clockLabel: Self.shortClockLabel(for: bucketStart),
                    deepMinutes: deep,
                    remMinutes: rem
                )
            )
        }
        return out
    }

    /// Sum of overlap (in minutes) between every `stage` sample and
    /// the supplied wall-clock window.
    private func stageMinutes(
        in window: ClosedRange<Date>,
        stage: SleepStageSample.Stage
    ) -> Double {
        let seconds = summary.samples
            .filter { $0.stage == stage }
            .reduce(0) { acc, sample in
                acc + overlap(a: sample.start...sample.end, b: window)
            }
        return seconds / 60
    }

    private func overlap(
        a: ClosedRange<Date>, b: ClosedRange<Date>
    ) -> TimeInterval {
        let lower = max(a.lowerBound, b.lowerBound)
        let upper = min(a.upperBound, b.upperBound)
        return max(0, upper.timeIntervalSince(lower))
    }

    private var peakStageMinutes: Double {
        buckets.map { max($0.deepMinutes, $0.remMinutes) }.max() ?? 0
    }

    private var hasAnyData: Bool {
        peakStageMinutes > 0
    }

    var body: some View {
        HourlyChartCard(title: "Sleep by Hour", subtitle: "minutes") {
            if hasAnyData {
                Chart {
                    ForEach(buckets) { bucket in
                        // One line per plotted stage — minutes-per-
                        // hour rendered side by side so each stage's
                        // trajectory across the night reads on its
                        // own. PointMark anchors every hour bucket so
                        // the segments read as per-hour readings, not
                        // a continuous signal.
                        LineMark(
                            x: .value("Hour", bucket.clockLabel),
                            y: .value("Minutes", bucket.deepMinutes),
                            series: .value("Stage", "Deep")
                        )
                        .foregroundStyle(by: .value("Stage", "Deep"))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)

                        PointMark(
                            x: .value("Hour", bucket.clockLabel),
                            y: .value("Minutes", bucket.deepMinutes)
                        )
                        .foregroundStyle(by: .value("Stage", "Deep"))
                        .symbolSize(28)

                        LineMark(
                            x: .value("Hour", bucket.clockLabel),
                            y: .value("Minutes", bucket.remMinutes),
                            series: .value("Stage", "REM")
                        )
                        .foregroundStyle(by: .value("Stage", "REM"))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)

                        PointMark(
                            x: .value("Hour", bucket.clockLabel),
                            y: .value("Minutes", bucket.remMinutes)
                        )
                        .foregroundStyle(by: .value("Stage", "REM"))
                        .symbolSize(28)
                    }
                }
                .chartForegroundStyleScale([
                    "Deep": library.eventColorPalette.deepSleep,
                    "REM": library.eventColorPalette.remSleep
                ])
                .chartLegend(.hidden)
                .chartXScale(domain: buckets.map(\.clockLabel))
                .chartYScale(domain: 0...60)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 20, 40, 60]) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let m = value.as(Double.self) {
                                Text("\(Int(m))")
                                    .font(.caption2.monospacedDigit())
                                    .frame(width: hourlyAxisLabelWidth, alignment: .trailing)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: buckets.map(\.clockLabel)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let label = value.as(String.self) {
                                Text(label).font(.caption2.monospacedDigit())
                            }
                        }
                    }
                }
                .frame(minHeight: 160)

                legend
            } else {
                // Defensive — `DayDetailView` already gates on a
                // non-nil summary, but the chart can render without
                // any in-window samples on a misaligned night. Show
                // a quiet placeholder so the panel doesn't collapse.
                Text("No Apple Watch sleep data fell within this night's CPAP window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
        }
    }

    /// Colour-keyed legend rendered outside the Chart's drawing
    /// surface so the `chartForegroundStyleScale` can't bleed its
    /// hues into the labels — the text always reads `.secondary`,
    /// matching the legend on `AHIHourlyChart`.
    private var legend: some View {
        FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
            legendDot(color: library.eventColorPalette.deepSleep, label: "Deep")
            legendDot(color: library.eventColorPalette.remSleep, label: "REM")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private static func shortClockLabel(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 0: return "12a"
        case 1..<12: return "\(hour)a"
        case 12: return "12p"
        default: return "\(hour - 12)p"
        }
    }
}
