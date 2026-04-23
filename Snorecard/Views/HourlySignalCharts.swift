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
    // Snap the anchor to the hour boundary at or before dayStart so
    // labels line up with wall-clock hours even when the first BRP
    // starts partway through an hour.
    let anchor = calendar.date(
        bySetting: .minute, value: 0,
        of: calendar.date(bySetting: .second, value: 0, of: dayStart) ?? dayStart
    ) ?? dayStart

    // Always span the full night's hour range — all four hourly
    // charts share the same axis so even signals that go quiet for
    // a stretch still occupy the same visual width. Missing hours
    // resolve to `stat.reduce([])` (which returns 0).
    let lastHour = Int((max(totalDuration, 1) / 3600).rounded(.up)) - 1
    guard lastHour >= 0 else { return [] }

    var grouped: [Int: [Double]] = [:]
    grouped.reserveCapacity(lastHour + 1)
    for point in points {
        let hour = Int((point.offset / 3600).rounded(.down))
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

/// Card chrome used by all three hourly charts. Matches
/// `AHIHourlyChart`'s inset plate so the panels below the stat
/// grid read as one cohesive set.
private struct HourlyChartCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var chart: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            chart()
                .frame(minHeight: 140)
        }
        .padding(14)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
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
        HourlyChartCard(title: "Leak by Hour", subtitle: "95th percentile · L/min") {
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
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
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
        HourlyChartCard(title: "Flow Limit by Hour", subtitle: "95th percentile · 0–1 scale") {
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
                )
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
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
        HourlyChartCard(title: "Tidal Volume by Hour", subtitle: "median · mL") {
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
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pressure by Hour (line)

struct PressureHourlyChart: View {
    @Environment(Library.self) private var library

    let pressure: [FlatPoint]
    let dayStart: Date
    let totalDuration: TimeInterval

    private var buckets: [HourlyBucket] {
        hourlyBuckets(pressure, dayStart: dayStart, totalDuration: totalDuration, stat: .median)
    }

    /// Line chart values — skips zero-filled empty hours so the
    /// trace doesn't dive to the floor on hours the CPAP wasn't
    /// recording. Those hours still appear on the x axis because
    /// the shared domain is driven by `buckets`.
    private var plottedBuckets: [HourlyBucket] {
        buckets.filter { $0.value > 0 }
    }

    private var valueRange: ClosedRange<Double> {
        let values = plottedBuckets.map(\.value)
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
        HourlyChartCard(title: "Mask Pressure by Hour", subtitle: "median · cmH₂O") {
            Chart(plottedBuckets) { bucket in
                LineMark(
                    x: .value("Hour", bucket.clockLabel),
                    y: .value("Pressure", bucket.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(library.eventColorPalette.pressureMedian)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Hour", bucket.clockLabel),
                    y: .value("Pressure", bucket.value)
                )
                .foregroundStyle(library.eventColorPalette.pressureMedian)
                .symbolSize(28)
            }
            .chartXScale(domain: buckets.map(\.clockLabel))
            .chartYScale(domain: valueRange)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
        }
    }
}

