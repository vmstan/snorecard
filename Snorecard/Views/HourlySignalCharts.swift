import SwiftUI
import Charts
import SnorecardKit

/// Hourly breakdown charts for the night's PLD signals. Mirrors the
/// visual treatment of `AHIHourlyChart` — same card chrome, same
/// short clock-hour labels — so the hourly panels at the bottom of
/// the day view read as one set. Leak and Flow Limit use peak-per-
/// hour (95th percentile) bars because the clinical framing of
/// both metrics is "how bad was the worst hour". Pressure uses a
/// median-per-hour line — matches the "Mask Pressure (Median)"
/// stat card and the Trends median line so the same quantity is
/// surfaced at every granularity.

// MARK: - Shared helpers

private struct HourlyBucket: Identifiable {
    var id: Int { startHour }
    let startHour: Int
    let clockLabel: String
    let value: Double
}

private enum HourlyStat {
    case mean
    case median
    case p95

    func reduce(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        switch self {
        case .mean:
            return values.reduce(0, +) / Double(values.count)
        case .median:
            let sorted = values.sorted()
            let count = sorted.count
            if count.isMultiple(of: 2) {
                return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
            }
            return sorted[count / 2]
        case .p95:
            let sorted = values.sorted()
            let rank = Double(sorted.count - 1) * 0.95
            let idx = min(sorted.count - 1, Int(rank.rounded()))
            return sorted[idx]
        }
    }
}

private func hourlyBuckets(
    _ points: [FlatPoint],
    dayStart: Date,
    totalDuration: TimeInterval,
    stat: HourlyStat
) -> [HourlyBucket] {
    let calendar = Calendar.current
    // Snap the anchor to the hour boundary at or before dayStart.
    // `dateInterval(of: .hour, for:)` returns the hour interval
    // containing dayStart; its `.start` is the snap-down boundary.
    // (`Calendar.date(bySetting:)` rolls forward to the next
    // matching value, so it lands on the *following* midnight for
    // any non-zero minute / second — not what we want.)
    let anchor = calendar.dateInterval(of: .hour, for: dayStart)?.start ?? dayStart

    // Always span the full night's hour range — all four hourly
    // charts share the same axis so even signals that go quiet for
    // a stretch still occupy the same visual width. Missing hours
    // resolve to `stat.reduce([])` (which returns 0).
    //
    // Bucket by wall-clock hour, not by `offset / 3600`. Points use
    // offsets relative to dayStart, but the axis labels are anchored
    // to the hour boundary at-or-before dayStart, so a point at
    // offset 0 (e.g. 23:38 wall-clock) belongs in the 23:00 bucket
    // — not the 0th bucket measured from 23:38. Without this shift
    // every signal point is filed under the previous hour's label.
    let anchorOffset = dayStart.timeIntervalSince(anchor)
    let anchorToEnd = totalDuration + anchorOffset
    let lastHour = Int((max(anchorToEnd, 1) / 3600).rounded(.up)) - 1
    guard lastHour >= 0 else { return [] }

    var grouped: [Int: [Double]] = [:]
    grouped.reserveCapacity(lastHour + 1)
    for point in points {
        let hour = Int(((point.offset + anchorOffset) / 3600).rounded(.down))
        grouped[hour, default: []].append(point.value)
    }

    var out: [HourlyBucket] = []
    out.reserveCapacity(lastHour + 1)
    for hour in 0...lastHour {
        let value = stat.reduce(grouped[hour] ?? [])
        let bucketStart = anchor.addingTimeInterval(TimeInterval(hour) * 3600)
        out.append(HourlyBucket(
            startHour: hour,
            clockLabel: shortClockLabel(for: bucketStart),
            value: value
        ))
    }
    return out
}

private func shortClockLabel(for date: Date) -> String {
    let hour = Calendar.current.component(.hour, from: date)
    switch hour {
    case 0: return "12a"
    case 1..<12: return "\(hour)a"
    case 12: return "12p"
    default: return "\(hour - 12)p"
    }
}

/// Card chrome shared by every per-hour chart on the day view —
/// AHI, Sleep, Leak, Flow Limit, Tidal Volume, Mask Pressure. The
/// title/subtitle layout, padding, and translucent backplate live
/// here so all six panels read as one cohesive set; callers slot
/// the Chart and any legend into the content closure and own the
/// chart's `.frame(minHeight:)`.
struct HourlyChartCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Shared y-axis label width for every per-hour chart on the day
/// view. Driving this through one constant keeps the leading edge
/// of every chart's plot area aligned across the column — without
/// the fixed width, each chart's y-axis column sizes to its own
/// label content and the X-axis hour labels drift horizontally.
/// 28pt fits the widest label we render (Flow Limit's "0.75").
let hourlyAxisLabelWidth: CGFloat = 28

/// Single-dot legend used by every single-series hourly chart on
/// the day view. Mirrors the multi-series legend pattern in
/// `AHIHourlyChart` / `SleepByHourChart` so the column reads as one
/// set: the chart subtitle carries the unit, the dot below
/// announces which statistic the trace represents.
@ViewBuilder
func singleSeriesLegend(color: Color, label: String) -> some View {
    HStack(spacing: 4) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Leak by Hour

struct LeakHourlyChart: View {
    @Environment(Library.self) private var library

    let leak: [FlatPoint]
    let dayStart: Date
    let totalDuration: TimeInterval

    private var buckets: [HourlyBucket] {
        hourlyBuckets(leak, dayStart: dayStart, totalDuration: totalDuration, stat: .p95)
    }

    private var peak: Double {
        buckets.map(\.value).max() ?? 0
    }

    var body: some View {
        HourlyChartCard(
            title: "Leak by Hour",
            subtitle: "L/min"
        ) {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Hour", bucket.clockLabel),
                    y: .value("Leak", bucket.value)
                )
                .foregroundStyle(library.eventColorPalette.leak)
            }
            .chartXScale(domain: buckets.map(\.clockLabel))
            .chartYScale(domain: 0 ... max(peak, 24))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)))
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
            .chartOverlay { proxy in
                // Dashed threshold line at 24 L/min, ResMed's large-leak
                // cutoff. Drawn in an overlay so it doesn't participate
                // in the bars' y scaling.
                GeometryReader { geo in
                    if let plot = proxy.plotFrame,
                       let y = proxy.position(forY: 24)
                    {
                        let rect = geo[plot]
                        Path { p in
                            p.move(to: CGPoint(x: rect.minX, y: y))
                            p.addLine(to: CGPoint(x: rect.maxX, y: y))
                        }
                        .stroke(
                            Color.severityHigh.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                    }
                }
            }
            .frame(minHeight: 140)

            singleSeriesLegend(
                color: library.eventColorPalette.leak,
                label: "95th"
            )
        }
    }
}

// MARK: - Flow Limit by Hour

struct FlowLimitHourlyChart: View {
    @Environment(Library.self) private var library

    let flowLimit: [FlatPoint]
    let dayStart: Date
    let totalDuration: TimeInterval

    private var buckets: [HourlyBucket] {
        hourlyBuckets(flowLimit, dayStart: dayStart, totalDuration: totalDuration, stat: .p95)
    }

    var body: some View {
        HourlyChartCard(
            title: "Flow Limit by Hour",
            subtitle: "0–1 scale"
        ) {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Hour", bucket.clockLabel),
                    y: .value("Flow Limit", bucket.value)
                )
                .foregroundStyle(library.eventColorPalette.flowLimit)
            }
            .chartXScale(domain: buckets.map(\.clockLabel))
            .chartYScale(domain: 0 ... 1)
            .chartYAxis {
                AxisMarks(
                    position: .leading,
                    values: [0, 0.25, 0.5, 0.75, 1]
                ) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)))
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
            .frame(minHeight: 140)

            singleSeriesLegend(
                color: library.eventColorPalette.flowLimit,
                label: "95th"
            )
        }
    }
}

// MARK: - Tidal Volume by Hour (line)

/// Per-hour median tidal volume. Matches the "Tidal Volume (Median)"
/// stat card and the Trends median line so the same quantity is
/// surfaced at every granularity. Rendered as a line for the same
/// reason Pressure is — it's a slowly-moving therapy signal whose
/// trajectory across the night is more informative than hour-by-hour
/// deltas.
struct TidalVolumeHourlyChart: View {
    @Environment(Library.self) private var library

    let tidalVolume: [FlatPoint]
    let dayStart: Date
    let totalDuration: TimeInterval

    private var buckets: [HourlyBucket] {
        hourlyBuckets(tidalVolume, dayStart: dayStart, totalDuration: totalDuration, stat: .median)
    }

    private var plottedBuckets: [HourlyBucket] {
        buckets.filter { $0.value > 0 }
    }

    private var valueRange: ClosedRange<Double> {
        let values = plottedBuckets.map(\.value)
        guard let minValue = values.min(),
              let maxValue = values.max() else {
            return 0 ... 800
        }
        let pad = Swift.max(25, (maxValue - minValue) * 0.15)
        return Swift.max(0, minValue - pad) ... (maxValue + pad)
    }

    var body: some View {
        HourlyChartCard(
            title: "Tidal Volume by Hour",
            subtitle: "mL"
        ) {
            Chart(plottedBuckets) { bucket in
                LineMark(
                    x: .value("Hour", bucket.clockLabel),
                    y: .value("Tidal Volume", bucket.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(library.eventColorPalette.tidalVolume)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Hour", bucket.clockLabel),
                    y: .value("Tidal Volume", bucket.value)
                )
                .foregroundStyle(library.eventColorPalette.tidalVolume)
                .symbolSize(28)
            }
            .chartXScale(domain: buckets.map(\.clockLabel))
            .chartYScale(domain: valueRange)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)))
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
            .frame(minHeight: 140)

            singleSeriesLegend(
                color: library.eventColorPalette.tidalVolume,
                label: "Median"
            )
        }
    }
}

// MARK: - Pressure by Hour (line)

struct PressureHourlyChart: View {
    @Environment(Library.self) private var library

    let pressure: [FlatPoint]
    let dayStart: Date
    let totalDuration: TimeInterval

    private var medianBuckets: [HourlyBucket] {
        hourlyBuckets(pressure, dayStart: dayStart, totalDuration: totalDuration, stat: .median)
    }

    private var p95Buckets: [HourlyBucket] {
        hourlyBuckets(pressure, dayStart: dayStart, totalDuration: totalDuration, stat: .p95)
    }

    /// Hours with no pressure samples reduce to zero on both stats —
    /// drop them so neither trace dives to the floor on hours the
    /// CPAP wasn't recording. The x axis still spans the full night
    /// because `medianBuckets` (unfiltered) drives `chartXScale`.
    private var plottedMedian: [HourlyBucket] {
        medianBuckets.filter { $0.value > 0 }
    }

    private var plottedP95: [HourlyBucket] {
        p95Buckets.filter { $0.value > 0 }
    }

    private var valueRange: ClosedRange<Double> {
        let values = (plottedMedian + plottedP95).map(\.value)
        guard let minValue = values.min(),
              let maxValue = values.max() else {
            return 0 ... 20
        }
        // Give the trace a small pad so it isn't pressed against
        // the plot edges on low-variance nights.
        let pad = Swift.max(0.5, (maxValue - minValue) * 0.15)
        return Swift.max(0, minValue - pad) ... (maxValue + pad)
    }

    var body: some View {
        HourlyChartCard(
            title: "Mask Pressure by Hour",
            subtitle: "cmH₂O"
        ) {
            Chart {
                ForEach(plottedP95) { bucket in
                    LineMark(
                        x: .value("Hour", bucket.clockLabel),
                        y: .value("Pressure", bucket.value),
                        series: .value("Series", "95th")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value("Series", "95th"))
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    PointMark(
                        x: .value("Hour", bucket.clockLabel),
                        y: .value("Pressure", bucket.value)
                    )
                    .foregroundStyle(by: .value("Series", "95th"))
                    .symbolSize(28)
                }

                ForEach(plottedMedian) { bucket in
                    LineMark(
                        x: .value("Hour", bucket.clockLabel),
                        y: .value("Pressure", bucket.value),
                        series: .value("Series", "Median")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value("Series", "Median"))
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    PointMark(
                        x: .value("Hour", bucket.clockLabel),
                        y: .value("Pressure", bucket.value)
                    )
                    .foregroundStyle(by: .value("Series", "Median"))
                    .symbolSize(28)
                }
            }
            .chartForegroundStyleScale([
                "95th": library.eventColorPalette.pressureP95,
                "Median": library.eventColorPalette.pressureMedian
            ])
            .chartLegend(.hidden)
            .chartXScale(domain: medianBuckets.map(\.clockLabel))
            .chartYScale(domain: valueRange)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)))
                                .font(.caption2.monospacedDigit())
                                .frame(width: hourlyAxisLabelWidth, alignment: .trailing)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: medianBuckets.map(\.clockLabel)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .frame(minHeight: 140)

            legend
        }
    }

    /// Colour-keyed legend rendered beneath the plot — same pattern
    /// as `AHIHourlyChart` and `SleepByHourChart` so a quick scan
    /// down the day view's hourly column reads consistently.
    private var legend: some View {
        FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
            legendDot(color: library.eventColorPalette.pressureMedian, label: "Median")
            legendDot(color: library.eventColorPalette.pressureP95, label: "95th")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

// MARK: - Glasgow Index by Hour (line)

/// Per-hour Glasgow Index line. Slices each session's flow signal
/// into wall-clock-hour chunks during waveform load and weighted-
/// averages multiple sessions in the same hour by inspiration count
/// — same aggregation `GlasgowIndex.computeDay` uses for the night-
/// wide aggregate. The trace is anchored to the same hour-aligned
/// x-axis as every other hourly chart on the day view, so a quick
/// scan down the column lines up cleanly. Y-axis pads ±0.1 around
/// the night's min and max so small per-hour deltas are visible.
struct GlasgowHourlyChart: View {
    @Environment(Library.self) private var library

    let slices: [WaveformBundle.GlasgowSessionHour]
    let dayStart: Date
    let totalDuration: TimeInterval

    /// Aggregate slices into one score per wall-clock hour by
    /// weighted-averaging on `inspirationCount`. Hours with no
    /// surviving slices are skipped — the line gaps over them.
    private var aggregated: [Date: Double] {
        var bucket: [Date: (weighted: Double, count: Int)] = [:]
        for entry in slices {
            var current = bucket[entry.slice.hourStart] ?? (0, 0)
            current.weighted += entry.slice.score * Double(entry.slice.inspirationCount)
            current.count += entry.slice.inspirationCount
            bucket[entry.slice.hourStart] = current
        }
        var out: [Date: Double] = [:]
        out.reserveCapacity(bucket.count)
        for (hour, value) in bucket where value.count > 0 {
            out[hour] = value.weighted / Double(value.count)
        }
        return out
    }

    /// Full hour-by-hour x-axis spanning the night. Mirrors the
    /// bucket logic in `AHIHourlyChart` / `hourlyBuckets` so the
    /// labels align exactly with the bar chart above.
    private var axisHours: [(label: String, hour: Date)] {
        let calendar = Calendar.current
        let anchor = calendar.dateInterval(of: .hour, for: dayStart)?.start ?? dayStart
        let anchorOffset = dayStart.timeIntervalSince(anchor)
        let anchorToEnd = totalDuration + anchorOffset
        let lastHour = Int((max(anchorToEnd, 1) / 3600).rounded(.up)) - 1
        guard lastHour >= 0 else { return [] }
        return (0...lastHour).map { offset in
            let hour = anchor.addingTimeInterval(TimeInterval(offset) * 3600)
            return (label: shortClockLabel(for: hour), hour: hour)
        }
    }

    /// Points on the x-axis that actually have a score. Hours
    /// without enough inspirations to score (or with no surviving
    /// session) drop out — the line gaps over them.
    private var plotted: [(label: String, score: Double)] {
        let agg = aggregated
        return axisHours.compactMap { entry in
            guard let score = agg[entry.hour] else { return nil }
            return (label: entry.label, score: score)
        }
    }

    /// Night-wide Glasgow score, weighted-averaged from the same
    /// slices the per-hour line plots. Matches `computeDay`'s
    /// aggregation, but stays consistent with whatever sessions
    /// survived `filteringInactiveSessions` (the standalone
    /// `computeDay` would re-include excluded ones).
    private var nightAverage: Double? {
        var weighted: Double = 0
        var count: Int = 0
        for entry in slices {
            weighted += entry.slice.score * Double(entry.slice.inspirationCount)
            count += entry.slice.inspirationCount
        }
        return count > 0 ? weighted / Double(count) : nil
    }

    /// ±0.1 around min/max of the plotted scores. When only a
    /// single hour has data the range still spans 0.2 so the
    /// single point doesn't render at the chart's vertical centre
    /// with no scale to read it against.
    private var valueRange: ClosedRange<Double> {
        let scores = plotted.map(\.score)
        guard let lo = scores.min(), let hi = scores.max() else {
            return 0 ... 1
        }
        return (lo - 0.1) ... (hi + 0.1)
    }

    var body: some View {
        HourlyChartCard(
            title: "Glasgow Index by Hour",
            subtitle: "lower is better"
        ) {
            Chart {
                ForEach(plotted, id: \.label) { point in
                    LineMark(
                        x: .value("Hour", point.label),
                        y: .value("Score", point.score)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(library.eventColorPalette.glasgowIndex)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    PointMark(
                        x: .value("Hour", point.label),
                        y: .value("Score", point.score)
                    )
                    .foregroundStyle(library.eventColorPalette.glasgowIndex)
                    .symbolSize(28)
                }
                if let avg = nightAverage {
                    RuleMark(y: .value("Night Average", avg))
                        .foregroundStyle(library.eventColorPalette.glasgowIndex.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartXScale(domain: axisHours.map(\.label))
            .chartYScale(domain: valueRange)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)))
                                .font(.caption2.monospacedDigit())
                                .frame(width: hourlyAxisLabelWidth, alignment: .trailing)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: axisHours.map(\.label)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .frame(minHeight: 140)

            FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                singleSeriesLegend(
                    color: library.eventColorPalette.glasgowIndex,
                    label: "Score"
                )
                if let avg = nightAverage {
                    HStack(spacing: 4) {
                        // Tiny dashed swatch mirroring the rule
                        // style above so the legend reads as one
                        // glance with the chart.
                        DashedSwatch(
                            color: library.eventColorPalette.glasgowIndex.opacity(0.5)
                        )
                        Text(String(format: "Night Avg %.2f", avg))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// 12pt-wide dashed line swatch used in the Glasgow chart legend
/// to label the night-average rule. Drawn with the same dash
/// pattern as the `RuleMark` so the swatch and the line read as
/// the same visual element.
private struct DashedSwatch: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
            )
        }
        .frame(width: 12, height: 8)
    }
}
