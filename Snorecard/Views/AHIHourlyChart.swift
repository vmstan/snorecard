import SwiftUI
import Charts
import SnorecardKit

/// Stacked column chart of apnea / hypopnea events bucketed by clock hour
/// across the night. Colour coding matches the event donut: red for
/// obstructive, purple for central, yellow for hypopnea. Bucketing walks
/// the events list and groups into whole-hour slots starting from
/// `dayStart`'s first full hour.
struct AHIHourlyChart: View {
    let events: [TimedEvent]
    let dayStart: Date

    private var buckets: [HourBucket] {
        guard !events.isEmpty else { return [] }

        let calendar = Calendar.current
        // Snap the first bucket to the hour boundary at or before dayStart so
        // a 22:39 session bucket starts at 22:00 rather than 22:39.
        let anchor = calendar.date(
            bySetting: .minute, value: 0,
            of: calendar.date(bySetting: .second, value: 0, of: dayStart) ?? dayStart
        ) ?? dayStart

        let minOffset = 0.0
        let maxOffset = events.map(\.offset).max() ?? 0
        let lastHour = Int((maxOffset / 3600).rounded(.down))
        let firstHour = Int((minOffset / 3600).rounded(.down))

        var out: [HourBucket] = []
        for hour in firstHour...lastHour {
            let start = TimeInterval(hour) * 3600
            let end = start + 3600
            var ob = 0
            var ce = 0
            var hy = 0
            for event in events where event.offset >= start && event.offset < end {
                let text = event.text.lowercased()
                if text.contains("obstructive") { ob += 1 }
                else if text.contains("central") { ce += 1 }
                else if text.contains("hypopnea") { hy += 1 }
            }
            let bucketStart = anchor.addingTimeInterval(start)
            out.append(
                HourBucket(
                    startHour: hour,
                    clockLabel: Self.shortClockLabel(for: bucketStart),
                    obstructive: ob,
                    central: ce,
                    hypopnea: hy
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
            Text("Events by hour")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 8)

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
                "Obstructive": Color.eventObstructive,
                "Central": Color.eventCentral,
                "Hypopnea": Color.eventHypopnea
            ])
            .chartLegend(.hidden)
            .chartYScale(domain: 0 ... max(peakEventCount, 1))
            .chartYAxis {
                AxisMarks(
                    position: .leading,
                    values: .automatic(desiredCount: min(4, max(1, peakEventCount)))
                )
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel() {
                        if let label = value.as(String.self) {
                            Text(label).font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .frame(minHeight: 140)
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
