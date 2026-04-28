import SwiftUI
import Charts
import SnorecardKit

/// Stacked column chart of apnea / hypopnea events bucketed by clock hour
/// across the night. Colour coding matches the event donut: red for
/// obstructive, blue for central, yellow for hypopnea. Bucketing walks
/// the events list and groups into whole-hour slots starting from
/// `dayStart`'s first full hour.
struct AHIHourlyChart: View {
    @Environment(Library.self) private var library

    let events: [TimedEvent]
    let dayStart: Date
    /// Total night duration in seconds. Drives the bucket range so
    /// every hourly chart on the day view shares the same x axis —
    /// quiet signals (few events, no leak, etc.) still span the
    /// full night instead of collapsing to a narrower plot.
    let totalDuration: TimeInterval

    private var buckets: [HourBucket] {
        let calendar = Calendar.current
        // Snap the first bucket to the hour boundary at or before
        // dayStart so a 22:39 session bucket starts at 22:00.
        // `Calendar.date(bySetting:value:of:)` would have been the
        // obvious choice here but it *rolls forward* to the next
        // matching component value — chaining `.second=0` then
        // `.minute=0` on 23:38:39 returns 24:00:00 (the next
        // midnight), not 23:00:00. `dateInterval(of: .hour, for:)`
        // returns the [start, end) of the hour containing dayStart,
        // whose `.start` is the snap-down hour boundary we want.
        let anchor = calendar.dateInterval(of: .hour, for: dayStart)?.start ?? dayStart

        // Distance from anchor to dayStart — events use offsets
        // relative to dayStart, but we group into hour slots
        // relative to anchor so the label and the contained data
        // describe the same wall-clock window.
        let anchorOffset = dayStart.timeIntervalSince(anchor)
        let anchorToEnd = totalDuration + anchorOffset
        let lastHour = Int((max(anchorToEnd, 1) / 3600).rounded(.up)) - 1
        guard lastHour >= 0 else { return [] }

        var grouped: [Int: (ob: Int, ce: Int, hy: Int)] = [:]
        for event in events {
            let bucket = Int(((event.offset + anchorOffset) / 3600).rounded(.down))
            guard bucket >= 0, bucket <= lastHour else { continue }
            let text = event.text.lowercased()
            var current = grouped[bucket] ?? (0, 0, 0)
            if text.contains("obstructive") { current.ob += 1 }
            else if text.contains("central") { current.ce += 1 }
            else if text.contains("hypopnea") { current.hy += 1 }
            grouped[bucket] = current
        }

        var out: [HourBucket] = []
        out.reserveCapacity(lastHour + 1)
        for hour in 0...lastHour {
            let bucketStart = anchor.addingTimeInterval(TimeInterval(hour) * 3600)
            let counts = grouped[hour] ?? (0, 0, 0)
            out.append(
                HourBucket(
                    startHour: hour,
                    clockLabel: Self.shortClockLabel(for: bucketStart),
                    obstructive: counts.ob,
                    central: counts.ce,
                    hypopnea: counts.hy
                )
            )
        }
        return out
    }

    private var peakEventCount: Int {
        buckets.map { $0.obstructive + $0.central + $0.hypopnea }.max() ?? 0
    }

    var body: some View {
        HourlyChartCard(title: "Events by Hour", subtitle: nil) {
            Chart {
                ForEach(buckets) { bucket in
                    BarMark(
                        x: .value("Hour", bucket.clockLabel),
                        y: .value("Count", bucket.obstructive)
                    )
                    .foregroundStyle(by: .value("Type", "Obstructive"))

                    BarMark(
                        x: .value("Hour", bucket.clockLabel),
                        y: .value("Count", bucket.hypopnea)
                    )
                    .foregroundStyle(by: .value("Type", "Hypopnea"))

                    BarMark(
                        x: .value("Hour", bucket.clockLabel),
                        y: .value("Count", bucket.central)
                    )
                    .foregroundStyle(by: .value("Type", "Central"))
                }
            }
            .chartForegroundStyleScale([
                "Obstructive": library.eventColorPalette.obstructive,
                "Central": library.eventColorPalette.central,
                "Hypopnea": library.eventColorPalette.hypopnea
            ])
            .chartLegend(.hidden)
            .chartXScale(domain: buckets.map(\.clockLabel))
            .chartYScale(domain: 0 ... max(peakEventCount, 1))
            .chartYAxis {
                AxisMarks(
                    position: .leading,
                    values: .automatic(desiredCount: min(4, max(1, peakEventCount)))
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

            legend
        }
    }

    /// Colour-keyed legend below the x-axis. Uses the clinical
    /// names ("Obstructive Apnea", and the user-preferred long
    /// form for the CA category from `library.centralEventLabel`)
    /// rather than the internal scale keys so the chart label
    /// matches what the user sees elsewhere. Built as a flow
    /// layout so it wraps cleanly on iPhone-width plates.
    private var legend: some View {
        FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
            legendItem("Obstructive Apnea", color: library.eventColorPalette.obstructive)
            legendItem("Hypopnea", color: library.eventColorPalette.hypopnea)
            legendItem(
                library.centralEventLabel.displayName,
                color: library.eventColorPalette.central
            )
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
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

    struct HourBucket: Identifiable {
        var id: Int { startHour }
        let startHour: Int
        let clockLabel: String
        let obstructive: Int
        let central: Int
        let hypopnea: Int
    }
}
