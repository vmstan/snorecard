import SwiftUI
import Charts
import SnorecardKit

/// Stacked column chart of Apple Watch sleep stages (deep / core / REM)
/// bucketed by clock hour, with the per-hour CPAP mask-on minutes
/// overlaid as a line on a secondary axis. Hour bucketing matches
/// `AHIHourlyChart` so the x-axis lines up with every other hourly
/// chart on the day view.
///
/// Awake / in-bed-only stages are deliberately excluded from the
/// stack — the chart's job is to compare *asleep architecture*
/// against CPAP usage, not to surface every category sample.
struct SleepByHourChart: View {
    @Environment(Library.self) private var library
    let summary: NightlySleepSummary
    let sessions: [SessionSegment]
    let dayStart: Date
    /// Total night duration in seconds. Drives the bucket range so
    /// every hourly chart on the day view shares the same x axis,
    /// matching `AHIHourlyChart`.
    let totalDuration: TimeInterval

    /// Label for the device-usage line — derived from the user's
    /// configured device type so the chart reads "BiPAP Usage" for
    /// a BiPAP user, "APAP Usage" for an APAP user, etc., matching
    /// the device-name conventions everywhere else in the app.
    private var deviceLabel: String {
        "\(library.deviceType(for: library.card).displayName) Usage"
    }

    private struct HourBucket: Identifiable {
        var id: Int { startHour }
        let startHour: Int
        let clockLabel: String
        /// Minutes of each asleep stage that fall inside this hour.
        let deepMinutes: Double
        let coreMinutes: Double
        let remMinutes: Double
        /// Minutes the user had the mask on during this hour
        /// (clamped 0…60 by construction).
        let cpapMinutes: Double
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
        // hour of CPAP usage gets its own bucket instead of being
        // clipped past the chart edge.
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
            let core = stageMinutes(in: bucketStart...bucketEnd, stage: .core)
            let rem = stageMinutes(in: bucketStart...bucketEnd, stage: .rem)

            // Mask-on minutes: intersect each session's wall-clock
            // window with this bucket and sum the overlap.
            var cpapSeconds: TimeInterval = 0
            for session in sessions {
                let sessionStart = dayStart.addingTimeInterval(session.startOffset)
                let sessionEnd = sessionStart.addingTimeInterval(session.duration)
                cpapSeconds += overlap(
                    a: sessionStart...sessionEnd,
                    b: bucketStart...bucketEnd
                )
            }
            let cpapMinutes = min(60, cpapSeconds / 60)

            out.append(
                HourBucket(
                    startHour: hour,
                    clockLabel: Self.shortClockLabel(for: bucketStart),
                    deepMinutes: deep,
                    coreMinutes: core,
                    remMinutes: rem,
                    cpapMinutes: cpapMinutes
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

    private var peakStackMinutes: Double {
        buckets.map { $0.deepMinutes + $0.coreMinutes + $0.remMinutes }.max() ?? 0
    }

    private var hasAnyData: Bool {
        peakStackMinutes > 0 || buckets.contains(where: { $0.cpapMinutes > 0 })
    }

    var body: some View {
        HourlyChartCard(title: "Sleep by Hour", subtitle: "minutes") {
            if hasAnyData {
                Chart {
                    ForEach(buckets) { bucket in
                        // Stacked bars — order matters for a stable
                        // visual stack: Deep at the bottom, Core in
                        // the middle, REM on top, mirroring the way
                        // Apple Health stacks its sleep ring.
                        BarMark(
                            x: .value("Hour", bucket.clockLabel),
                            y: .value("Minutes", bucket.deepMinutes)
                        )
                        .foregroundStyle(by: .value("Stage", "Deep"))

                        BarMark(
                            x: .value("Hour", bucket.clockLabel),
                            y: .value("Minutes", bucket.coreMinutes)
                        )
                        .foregroundStyle(by: .value("Stage", "Core"))

                        BarMark(
                            x: .value("Hour", bucket.clockLabel),
                            y: .value("Minutes", bucket.remMinutes)
                        )
                        .foregroundStyle(by: .value("Stage", "REM"))

                        // Device-usage line + marker on the secondary
                        // axis. PointMark anchors each hour so the
                        // line reads as a per-hour reading rather
                        // than a continuous signal.
                        LineMark(
                            x: .value("Hour", bucket.clockLabel),
                            y: .value(deviceLabel, bucket.cpapMinutes)
                        )
                        .foregroundStyle(by: .value("Stage", deviceLabel))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)

                        PointMark(
                            x: .value("Hour", bucket.clockLabel),
                            y: .value(deviceLabel, bucket.cpapMinutes)
                        )
                        .foregroundStyle(by: .value("Stage", deviceLabel))
                        .symbolSize(36)
                    }
                }
                .chartForegroundStyleScale([
                    "Deep": library.eventColorPalette.deepSleep,
                    "Core": library.eventColorPalette.coreSleep,
                    "REM": library.eventColorPalette.remSleep,
                    deviceLabel: Color.timelineSessionFill
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
            legendDot(color: library.eventColorPalette.coreSleep, label: "Core")
            legendDot(color: library.eventColorPalette.remSleep, label: "REM")
            legendLine(color: .timelineSessionFill, label: deviceLabel)
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

    private func legendLine(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 14, height: 3)
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
