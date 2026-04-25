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
        // dayStart so a 22:39 session bucket starts at 22:00 — and
        // bucketing by wall-clock hour means events stay aligned
        // with the label they're filed under.
        let anchor = calendar.date(
            bySetting: .minute, value: 0,
            of: calendar.date(bySetting: .second, value: 0, of: dayStart) ?? dayStart
        ) ?? dayStart

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
        VStack(alignment: .leading, spacing: 8) {
            // Now that the panel is wrapped in a StatCard-style
            // plate, match the card label treatment — small
            // uppercase caption — instead of the in-place chart
            // headline used for free-floating charts.
            Text("Events by Hour")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

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
                )
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
        // Card chrome — matches the StatCard treatment so the
        // events-by-hour panel reads as part of the same set as
        // the metrics grid above it instead of a loose chart.
        .padding(14)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    /// Colour-keyed legend below the x-axis. Uses the clinical
    /// names ("Obstructive Apnea", "Clear Airway") rather than the
    /// internal scale keys so the chart label matches what the
    /// user sees in journal entries and AI narratives. Built as a
    /// flow layout so it wraps cleanly on iPhone-width plates.
    private var legend: some View {
        FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
            legendItem("Obstructive Apnea", color: library.eventColorPalette.obstructive)
            legendItem("Hypopnea", color: library.eventColorPalette.hypopnea)
            legendItem("Clear Airway", color: library.eventColorPalette.central)
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
