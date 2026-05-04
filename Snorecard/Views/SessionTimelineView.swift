import SwiftUI
import Charts
import SnorecardKit

/// Horizontal strip visualising each session as a bar positioned on the day's
/// active time axis. Rendered as a real SwiftUI Chart (with the same X scale
/// and Y-axis column width as the data charts below) so the plot area — and
/// therefore the gaps between sessions — line up pixel-perfect.
struct SessionTimelineView: View {
    @Environment(Library.self) private var library
    let bundle: WaveformBundle
    /// Optional Apple Watch sleep summary for the night. When
    /// present, deep / core / REM samples render as a colour-tinted
    /// backdrop behind the session bars so the user can read the
    /// CPAP timeline and the sleep architecture in one place.
    var sleepSummary: NightlySleepSummary? = nil
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

    private struct StageBar: Identifiable {
        let id: String
        let startOffset: TimeInterval
        let endOffset: TimeInterval
        let color: Color
    }

    /// Convert the Apple Watch summary's stage samples into the
    /// timeline's offset space. Awake / inBed records are filtered
    /// out — the user already gets the in-bed envelope from the
    /// session bars themselves and an awake tint would obscure
    /// them. Stages are clipped to the bundle's `[0, totalDuration]`
    /// so a sample bracketing the night doesn't bleed past the
    /// chart edge.
    private var stageBars: [StageBar] {
        guard let summary = sleepSummary else { return [] }
        let palette = library.eventColorPalette
        let totalDuration = bundle.totalDuration
        return summary.samples
            .filter { $0.stage != .inBed && $0.stage != .awake }
            .compactMap { sample in
                let start = sample.start.timeIntervalSince(bundle.dayStart)
                let end = sample.end.timeIntervalSince(bundle.dayStart)
                let clippedStart = max(0, start)
                let clippedEnd = min(totalDuration, end)
                guard clippedEnd > clippedStart else { return nil }
                let color: Color = {
                    switch sample.stage {
                    case .deep: return palette.deepSleep
                    case .core, .asleepUnspecified: return palette.coreSleep
                    case .rem: return palette.remSleep
                    case .awake, .inBed: return .clear
                    }
                }()
                return StageBar(
                    id: sample.id,
                    startOffset: clippedStart,
                    endOffset: clippedEnd,
                    color: color
                )
            }
    }

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
                // Sleep-stage backdrop (deep / core / REM) — drawn
                // first so the session bars and event rules below
                // sit on top. ~55 % opacity reads as a tint rather
                // than a dominant element; the gaps between
                // sessions still show the stage colour clearly.
                ForEach(stageBars) { bar in
                    RectangleMark(
                        xStart: .value("Stage Start", bar.startOffset),
                        xEnd: .value("Stage End", bar.endOffset),
                        yStart: .value("Bottom", 0),
                        yEnd: .value("Top", 1)
                    )
                    .foregroundStyle(bar.color.opacity(0.55))
                }

                ForEach(bundle.sessions) { session in
                    let brief = isBrief(session)
                    let manuallyExcluded = isExcluded(session)
                    let dimmed = brief || manuallyExcluded
                    RectangleMark(
                        xStart: .value("Start", session.startOffset),
                        xEnd: .value("End", session.startOffset + session.duration),
                        yStart: .value("Bottom", 0),
                        yEnd: .value("Top", 1)
                    )
                    .foregroundStyle(
                        Color.timelineSessionFill
                            .opacity(dimmed ? 0.25 : 1.0)
                    )
                    .cornerRadius(3)
                    .annotation(position: .overlay, alignment: .leading, spacing: 0) {
                        // Invisible accessibility / tooltip anchor per bar.
                        // Right-click (macOS) / long-press (iOS) opens a
                        // context menu so the user can drop a stray
                        // session — daytime mask test, brief fitting —
                        // out of the day's totals without affecting the
                        // canonical disk cache. Brief sessions skip the
                        // menu because the auto-exclude rule already
                        // drops them and a manual toggle wouldn't move
                        // the totals.
                        Color.clear
                            .contentShape(Rectangle())
                            .help(tooltip(for: session))
                            .contextMenu {
                                if !brief, let key = sessionKey(for: session) {
                                    Button {
                                        library.toggleSessionExclusion(
                                            key,
                                            forDate: dayDate
                                        )
                                    } label: {
                                        Label(
                                            manuallyExcluded
                                                ? "Include in Totals"
                                                : "Exclude from Totals",
                                            systemImage: manuallyExcluded
                                                ? "checkmark.circle"
                                                : "minus.circle"
                                        )
                                    }
                                }
                            }
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
        var summary = "\(times)  •  \(formatDuration(session.duration))  •  \(session.sourceFilename)"
        if isBrief(session) {
            summary += "  •  auto-excluded (under 2 min)"
        } else if isExcluded(session) {
            summary += "  •  excluded"
        }
        return summary
    }

    /// Sessions shorter than the aggregate's auto-exclude threshold
    /// (mirrored here so the timeline can dim them without re-reading
    /// the BRP header). Kept in sync with
    /// `DailyStatistics.aggregate(minSessionSeconds:)`.
    private func isBrief(_ session: SessionSegment) -> Bool {
        session.duration < 120
    }

    /// Calendar-day midnight for this timeline, used as the lookup key
    /// when toggling a session's exclusion. Matches the `ResMedDay.date`
    /// the importer assigns from the device's day-folder name.
    private var dayDate: Date {
        Calendar.current.startOfDay(for: bundle.dayStart)
    }

    /// Resolve the session's stable key (`YYYYMMDD_HHMMSS`) from its
    /// source BRP filename. `nil` for files that don't follow the
    /// device-stamped naming convention — those sessions can't be
    /// reliably re-identified on the next launch, so the exclusion
    /// affordance simply doesn't appear for them.
    private func sessionKey(for session: SessionSegment) -> String? {
        let parts = session.sourceFilename.split(separator: "_")
        guard parts.count >= 2,
              parts[0].count == 8,
              parts[1].count == 6 else { return nil }
        return "\(parts[0])_\(parts[1])"
    }

    private func isExcluded(_ session: SessionSegment) -> Bool {
        guard let key = sessionKey(for: session) else { return false }
        return library.isSessionExcluded(key)
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
