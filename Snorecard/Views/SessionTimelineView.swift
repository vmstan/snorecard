import SwiftUI
import Charts
import SnorecardKit

/// Horizontal strip visualising each session as a bar positioned on the day's
/// active time axis. Rendered as a real SwiftUI Chart (with the same X scale
/// and Y-axis column width as the data charts below) so the plot area — and
/// therefore the gaps between sessions — line up pixel-perfect.
struct SessionTimelineView: View {
    let bundle: WaveformBundle
    /// Callback fired when the user taps a point on the timeline
    /// strip. Passes the tapped offset in seconds from
    /// `bundle.dayStart`. Caller typically animates the viewport.
    var onJumpToTime: ((TimeInterval) -> Void)? = nil
    /// Callback fired continuously while the user is dragging the
    /// viewport. Passes the live time offset under the finger.
    /// Caller should update the viewport *without* animating so
    /// the shaded band tracks the pointer smoothly.
    var onDragToTime: ((TimeInterval) -> Void)? = nil
    /// When the waveform section is zoomed in, these describe the visible
    /// window so the timeline can shade a viewport indicator over that
    /// portion of the night.
    var viewportStart: TimeInterval = 0
    var viewportLength: TimeInterval = 0

    /// Axis the current drag has committed to. `nil` while we're
    /// still deciding (first few points of motion); `.horizontal`
    /// locks into timeline scrubbing for the rest of the gesture;
    /// `.ignore` stays out of the way so vertical scroll on the
    /// enclosing sheet / ScrollView can proceed unimpeded.
    @State private var dragAxis: DragAxis? = nil

    private enum DragAxis { case horizontal, ignore }

    /// Minimum travel before the timeline drag activates. On iOS the
    /// threshold is larger than macOS so a finger briefly grazing
    /// the strip on its way to a vertical scroll doesn't grab the
    /// viewport. On macOS a cursor can be precise at 6 pt.
    private var dragMinimumDistance: CGFloat {
        #if os(iOS)
        12
        #else
        6
        #endif
    }

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
                // Match the data-chart Y-axis position (trailing)
                // so the plot areas line up vertically.
                AxisMarks(position: .trailing, values: [0.5]) { _ in
                    AxisValueLabel {
                        Text(" ")
                            .font(.caption2.monospacedDigit())
                            .frame(width: 32, alignment: .leading)
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
                        // Tap anywhere on the timeline jumps the
                        // viewport so the tapped time is centered.
                        .onTapGesture { location in
                            notifyJump(
                                atScreenX: location.x,
                                proxy: proxy,
                                geo: geo
                            )
                        }
                        // Drag pans the viewport in real time — the
                        // shaded band follows the finger / pointer.
                        // `simultaneousGesture` + a sticky axis
                        // decision so a dominantly-vertical swipe is
                        // ignored for the rest of the gesture, letting
                        // the enclosing ScrollView scroll the page
                        // past the timeline without the viewport
                        // also jumping around.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: dragMinimumDistance)
                                .onChanged { value in
                                    if dragAxis == nil {
                                        let dx = abs(value.translation.width)
                                        let dy = abs(value.translation.height)
                                        // Wait for a clear direction
                                        // before deciding. Below the
                                        // threshold, keep both axes
                                        // live so a late vertical
                                        // component can still take over.
                                        guard max(dx, dy) >= 8 else { return }
                                        dragAxis = dx > dy ? .horizontal : .ignore
                                    }
                                    guard dragAxis == .horizontal else { return }
                                    notifyDrag(
                                        atScreenX: value.location.x,
                                        proxy: proxy,
                                        geo: geo
                                    )
                                }
                                .onEnded { _ in
                                    dragAxis = nil
                                }
                        )
                }
            }
            .frame(height: 57)
        }
    }

    /// Translate a screen-space x coordinate (within the chart
    /// overlay) to a time offset in seconds and fire the
    /// `onJumpToTime` callback. Clamps to the plot width so the
    /// caller's viewport-centering logic always receives an offset
    /// that lies on the timeline.
    private func notifyJump(
        atScreenX screenX: CGFloat,
        proxy: ChartProxy,
        geo: GeometryProxy
    ) {
        if let offset = offsetInPlot(screenX, proxy: proxy, geo: geo) {
            onJumpToTime?(offset)
        }
    }

    /// Same translation as `notifyJump` but routes to the drag
    /// callback, which the caller wires up with no animation so the
    /// shaded band tracks the pointer at 60 fps without queueing
    /// overlapping easings.
    private func notifyDrag(
        atScreenX screenX: CGFloat,
        proxy: ChartProxy,
        geo: GeometryProxy
    ) {
        if let offset = offsetInPlot(screenX, proxy: proxy, geo: geo) {
            onDragToTime?(offset)
        }
    }

    private func offsetInPlot(
        _ screenX: CGFloat,
        proxy: ChartProxy,
        geo: GeometryProxy
    ) -> Double? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geo[plotFrame]
        let xInPlot = screenX - frame.origin.x
        let clamped = min(max(xInPlot, 0), frame.width)
        return proxy.value(atX: clamped)
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
