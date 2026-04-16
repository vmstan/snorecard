import SwiftUI
import Charts
import SnorecardKit

/// Horizontal strip visualising each session as a bar positioned on the day's
/// active time axis. Rendered as a real SwiftUI Chart (with the same X scale
/// and Y-axis column width as the data charts below) so the plot area — and
/// therefore the gaps between sessions — line up pixel-perfect.
struct SessionTimelineView: View {
    let bundle: WaveformBundle
    /// Callback fired when the user taps a point on the timeline strip.
    /// Passes the tapped offset in seconds from `bundle.dayStart`.
    var onJumpToTime: ((TimeInterval) -> Void)? = nil
    /// When the waveform section is zoomed in, these describe the visible
    /// window so the timeline can shade a viewport indicator over that
    /// portion of the night.
    var viewportStart: TimeInterval = 0
    var viewportLength: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(bundle.sessions) { session in
                    RectangleMark(
                        xStart: .value("Start", session.startOffset),
                        xEnd: .value("End", session.startOffset + session.duration),
                        yStart: .value("Bottom", 0),
                        yEnd: .value("Top", 1)
                    )
                    .foregroundStyle(Color.timelineSessionFill)
                    .cornerRadius(3)
                    .annotation(position: .overlay, alignment: .leading, spacing: 0) {
                        // Invisible accessibility / tooltip anchor per bar.
                        Color.clear
                            .contentShape(Rectangle())
                            .help(tooltip(for: session))
                    }
                }

                ForEach(Array(bundle.events.enumerated()), id: \.offset) { _, event in
                    RuleMark(x: .value("Event", event.offset))
                        .foregroundStyle(color(for: event.text))
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                }

                if showsViewportIndicator {
                    // Translucent shaded band marking the window the
                    // waveform charts are currently showing.
                    RectangleMark(
                        xStart: .value("VP Start", viewportStart),
                        xEnd: .value("VP End", viewportStart + viewportLength),
                        yStart: .value("Bottom", 0),
                        yEnd: .value("Top", 1)
                    )
                    .foregroundStyle(Color.timelineViewportFill)
                    .cornerRadius(2)
                    RuleMark(x: .value("VP Start", viewportStart))
                        .foregroundStyle(Color.timelineViewportEdge)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    RuleMark(x: .value("VP End", viewportStart + viewportLength))
                        .foregroundStyle(Color.timelineViewportEdge)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartYScale(domain: 0 ... 1)
            .chartYAxis {
                // Match the data-chart Y-axis width exactly so the plot areas
                // align vertically.
                AxisMarks(position: .leading, values: [0.5]) { _ in
                    AxisValueLabel {
                        Text(" ")
                            .font(.caption2.monospacedDigit())
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    if let seconds = value.as(Double.self) {
                        AxisValueLabel {
                            Text(clockLabel(for: seconds))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .chartXScale(domain: 0 ... max(bundle.totalDuration, 1))
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { event in
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let frame = geo[plotFrame]
                                    let xInPlot = event.location.x - frame.origin.x
                                    guard xInPlot >= 0, xInPlot <= frame.width else { return }
                                    if let offset: Double = proxy.value(atX: xInPlot) {
                                        onJumpToTime?(offset)
                                    }
                                }
                        )
                }
            }
            .frame(height: 57)
        }
    }

    private var showsViewportIndicator: Bool {
        viewportLength > 0 && viewportLength < bundle.totalDuration
    }

    private func tooltip(for session: SessionSegment) -> String {
        let start = bundle.dayStart.addingTimeInterval(session.startOffset)
        let end = start.addingTimeInterval(session.duration)
        let times = "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        return "\(times)  •  \(formatDuration(session.duration))  •  \(session.sourceFilename)"
    }

    private func clockLabel(for offset: TimeInterval) -> String {
        bundle.dayStart.addingTimeInterval(offset)
            .formatted(date: .omitted, time: .shortened)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = total % 3600 / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func color(for text: String) -> Color {
        let lower = text.lowercased()
        if lower.contains("obstructive") { return .eventObstructive }
        if lower.contains("central") { return .eventCentral }
        if lower.contains("hypopnea") { return .eventHypopnea }
        return .gray
    }
}
