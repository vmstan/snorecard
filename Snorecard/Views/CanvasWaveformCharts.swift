import SwiftUI

// MARK: - Canvas-backed waveform charts
//
// Drop-in replacements for the SwiftUI-Charts renderers that used to
// back every chart in `WaveformSection`. Each variant strokes the
// visible trace as a single Path per session and flattens it through
// `.drawingGroup()` so the GPU does the rasterization — orders of
// magnitude faster than `LineMark` ForEach once a single chart gets
// into the tens of thousands of points.
//
// Design notes carried forward from the original BreathingCanvasChart
// experiment (git commit 1b32266):
//
// - One stroked `Path` per session keeps GPU path count minimal.
// - `.drawingGroup()` flattens the Canvas output into a Metal texture
//   so re-layout doesn't re-rasterize.
// - The dashed hover rule and tap probe live in a SwiftUI overlay
//   (not inside the Canvas) so hover changes don't invalidate the
//   expensive path stroke.
// - Equatable conformance on every public chart so the
//   subview short-circuit engages on pure hover / scroll updates.
// - Drag-to-pan feeds `axes.scrollBinding` the same way SwiftUI
//   Charts' `.chartScrollPosition` did.

// MARK: - Public chart variants

/// Canvas equivalent of `SignalLineChart` — line (or stepped line)
/// with an optional dashed zero baseline, horizontal threshold, and
/// event rectangles behind the trace.
struct CanvasSignalLineChart: View, Equatable {
    let title: String
    let unit: String
    let points: [FlatPoint]
    let events: [TimedEvent]
    let color: Color
    let zeroReference: Bool
    let stepped: Bool
    let thresholdY: Double?
    let yDomain: ClosedRange<Double>?
    let hoverOffset: TimeInterval?
    let axes: SharedAxisConfig
    /// Fade the stroke vertically from `color` at the top to a
    /// muted version at the bottom. Opt-in per chart so Leak and
    /// Tidal Volume pick it up while Breathing keeps its flat,
    /// high-contrast trace.
    var gradient: Bool = false

    nonisolated static func == (lhs: CanvasSignalLineChart, rhs: CanvasSignalLineChart) -> Bool {
        lhs.title == rhs.title
            && lhs.unit == rhs.unit
            && lhs.points.count == rhs.points.count
            && lhs.points.first?.offset == rhs.points.first?.offset
            && lhs.points.last?.offset == rhs.points.last?.offset
            && lhs.events.count == rhs.events.count
            && lhs.zeroReference == rhs.zeroReference
            && lhs.stepped == rhs.stepped
            && lhs.thresholdY == rhs.thresholdY
            && lhs.yDomain == rhs.yDomain
            && lhs.hoverOffset == rhs.hoverOffset
            && lhs.axes == rhs.axes
            && lhs.gradient == rhs.gradient
    }

    var body: some View {
        CanvasPlotShell(
            title: title,
            unit: unit,
            yDomain: effectiveYDomain,
            axes: axes,
            hoverOffset: hoverOffset,
            legend: nil
        ) { context, size, math in
            if zeroReference,
               let y = math.yPixel(for: 0)
            {
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: y))
                zero.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    zero,
                    with: .color(Color.red.opacity(0.7)),
                    style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])
                )
            }
            if let thresholdY,
               let y = math.yPixel(for: thresholdY)
            {
                var rule = Path()
                rule.move(to: CGPoint(x: 0, y: y))
                rule.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    rule,
                    with: .color(Color.red.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }
            drawEventRects(events, in: context, size: size, math: math)
            if gradient {
                fillAreaBelow(
                    points,
                    color: color,
                    topOpacity: 0.35,
                    stepped: stepped,
                    baselineY: size.height,
                    in: context,
                    math: math
                )
            }
            strokeSeries(
                points,
                color: color,
                lineWidth: 1,
                stepped: stepped,
                in: context,
                math: math
            )
        }
    }

    /// Y domain used for the plot. Falls back to an auto-fit range
    /// computed from the series if no explicit domain was supplied,
    /// so the trace always fills the plot area.
    private var effectiveYDomain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        return autoYDomain(
            points,
            symmetricZero: zeroReference,
            defaultMax: 30
        )
    }
}

/// Canvas equivalent of `SignalAreaChart` — filled area used for
/// 0–1 / 0–5 index signals (snore, flow limitation).
struct CanvasSignalAreaChart: View, Equatable {
    let title: String
    let subtitle: String
    let points: [FlatPoint]
    let color: Color
    let yDomain: ClosedRange<Double>
    let hoverOffset: TimeInterval?
    let axes: SharedAxisConfig

    nonisolated static func == (lhs: CanvasSignalAreaChart, rhs: CanvasSignalAreaChart) -> Bool {
        lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.points.count == rhs.points.count
            && lhs.points.first?.offset == rhs.points.first?.offset
            && lhs.points.last?.offset == rhs.points.last?.offset
            && lhs.yDomain == rhs.yDomain
            && lhs.hoverOffset == rhs.hoverOffset
            && lhs.axes == rhs.axes
    }

    var body: some View {
        CanvasPlotShell(
            title: title,
            subtitleOverride: subtitle,
            yDomain: yDomain,
            axes: axes,
            hoverOffset: hoverOffset,
            legend: nil
        ) { context, size, math in
            fillSeries(
                points,
                color: color.opacity(0.55),
                stepped: true,
                baselineY: math.yPixel(for: yDomain.lowerBound) ?? size.height,
                in: context,
                math: math
            )
        }
    }
}

/// Canvas equivalent of `PressureChart` — renders IPAP / EPAP / mask
/// as three stepped lines with a small legend chip row above the
/// plot area.
struct CanvasPressureChart: View, Equatable {
    let title: String
    let unit: String
    let ipap: [FlatPoint]
    let epap: [FlatPoint]
    let fallback: [FlatPoint]
    let yDomain: ClosedRange<Double>?
    let hoverOffset: TimeInterval?
    let axes: SharedAxisConfig

    nonisolated static func == (lhs: CanvasPressureChart, rhs: CanvasPressureChart) -> Bool {
        lhs.title == rhs.title
            && lhs.unit == rhs.unit
            && lhs.ipap.count == rhs.ipap.count
            && lhs.ipap.first?.offset == rhs.ipap.first?.offset
            && lhs.ipap.last?.offset == rhs.ipap.last?.offset
            && lhs.epap.count == rhs.epap.count
            && lhs.epap.first?.offset == rhs.epap.first?.offset
            && lhs.epap.last?.offset == rhs.epap.last?.offset
            && lhs.fallback.count == rhs.fallback.count
            && lhs.fallback.first?.offset == rhs.fallback.first?.offset
            && lhs.fallback.last?.offset == rhs.fallback.last?.offset
            && lhs.yDomain == rhs.yDomain
            && lhs.hoverOffset == rhs.hoverOffset
            && lhs.axes == rhs.axes
    }

    var body: some View {
        CanvasPlotShell(
            title: title,
            unit: unit,
            yDomain: effectiveYDomain,
            axes: axes,
            hoverOffset: hoverOffset,
            legend: legendEntries
        ) { context, size, math in
            // Fill all traces first so each line's own stroke lands on
            // top of every wash — avoids one trace's gradient covering
            // another trace's line.
            if !ipap.isEmpty {
                fillAreaBelow(
                    ipap,
                    color: .chartOrange,
                    topOpacity: 0.35,
                    stepped: true,
                    baselineY: size.height,
                    in: context,
                    math: math
                )
            }
            if !epap.isEmpty {
                fillAreaBelow(
                    epap,
                    color: .chartBlue,
                    topOpacity: 0.35,
                    stepped: true,
                    baselineY: size.height,
                    in: context,
                    math: math
                )
            }
            if !fallback.isEmpty {
                fillAreaBelow(
                    fallback,
                    color: .purple,
                    topOpacity: 0.35,
                    stepped: true,
                    baselineY: size.height,
                    in: context,
                    math: math
                )
            }
            if !ipap.isEmpty {
                strokeSeries(
                    ipap,
                    color: .chartOrange,
                    lineWidth: 1.2,
                    stepped: true,
                    in: context,
                    math: math
                )
            }
            if !epap.isEmpty {
                strokeSeries(
                    epap,
                    color: .chartBlue,
                    lineWidth: 1.2,
                    stepped: true,
                    in: context,
                    math: math
                )
            }
            if !fallback.isEmpty {
                strokeSeries(
                    fallback,
                    color: .purple,
                    lineWidth: 1,
                    stepped: true,
                    in: context,
                    math: math
                )
            }
        }
    }

    private var legendEntries: [CanvasLegendEntry] {
        var out: [CanvasLegendEntry] = []
        if !ipap.isEmpty { out.append(.init(label: "IPAP", color: .chartOrange)) }
        if !epap.isEmpty { out.append(.init(label: "EPAP", color: .chartBlue)) }
        if !fallback.isEmpty { out.append(.init(label: "Mask", color: .purple)) }
        return out
    }

    private var effectiveYDomain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        let combined = ipap + epap + fallback
        return autoYDomain(combined, symmetricZero: false, defaultMax: 20)
    }
}

// MARK: - Equatable wrappers (match the old Equatable* API shape)

struct EquatableCanvasSignalLineChart: View {
    let title: String
    let unit: String
    let points: [FlatPoint]
    let events: [TimedEvent]
    let color: Color
    let zeroReference: Bool
    let stepped: Bool
    let thresholdY: Double?
    var yDomain: ClosedRange<Double>? = nil
    let hoverOffset: TimeInterval?
    let axes: SharedAxisConfig
    var gradient: Bool = false

    var body: some View {
        CanvasSignalLineChart(
            title: title,
            unit: unit,
            points: points,
            events: events,
            color: color,
            zeroReference: zeroReference,
            stepped: stepped,
            thresholdY: thresholdY,
            yDomain: yDomain,
            hoverOffset: hoverOffset,
            axes: axes,
            gradient: gradient
        )
        .equatable()
    }
}

struct EquatableCanvasSignalAreaChart: View {
    let title: String
    let subtitle: String
    let points: [FlatPoint]
    let color: Color
    let yDomain: ClosedRange<Double>
    let hoverOffset: TimeInterval?
    let axes: SharedAxisConfig

    var body: some View {
        CanvasSignalAreaChart(
            title: title,
            subtitle: subtitle,
            points: points,
            color: color,
            yDomain: yDomain,
            hoverOffset: hoverOffset,
            axes: axes
        )
        .equatable()
    }
}

struct EquatableCanvasPressureChart: View {
    let title: String
    let unit: String
    let ipap: [FlatPoint]
    let epap: [FlatPoint]
    let fallback: [FlatPoint]
    let yDomain: ClosedRange<Double>?
    let hoverOffset: TimeInterval?
    let axes: SharedAxisConfig

    var body: some View {
        CanvasPressureChart(
            title: title,
            unit: unit,
            ipap: ipap,
            epap: epap,
            fallback: fallback,
            yDomain: yDomain,
            hoverOffset: hoverOffset,
            axes: axes
        )
        .equatable()
    }
}

// MARK: - Shell

fileprivate struct CanvasLegendEntry: Equatable {
    let label: String
    let color: Color
}

/// Shared chart shell: title row, Y-axis labels column, Canvas plot
/// area, X-axis labels row. The `draw` closure renders into the
/// Canvas; the shell adds the hover rule + tap/drag gestures on top.
fileprivate struct CanvasPlotShell: View {
    let title: String
    var unit: String? = nil
    var subtitleOverride: String? = nil
    let yDomain: ClosedRange<Double>
    let axes: SharedAxisConfig
    let hoverOffset: TimeInterval?
    let legend: [CanvasLegendEntry]?
    let draw: (GraphicsContext, CGSize, CanvasAxesMath) -> Void

    /// Y label column width — matches SwiftUI Charts' 32pt trailing
    /// axis treatment used in `SharedAxesModifier` so vertical
    /// alignment across the stack stays intact.
    private static let yAxisWidth: CGFloat = 40
    private static let xAxisHeight: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ChartSubviewTitle(
                    title: title,
                    subtitle: resolvedSubtitle
                )
                if let legend {
                    Spacer()
                    legendRow(legend)
                }
            }
            // Trailing-align the header to the plot area (which sits
            // inside the Y-axis label column) so the legend chips don't
            // spill past the plot's right edge.
            .padding(.trailing, Self.yAxisWidth)
            GeometryReader { geo in
                let plotWidth = max(0, geo.size.width - Self.yAxisWidth)
                let plotHeight = max(0, geo.size.height - Self.xAxisHeight)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        plotArea(size: CGSize(width: plotWidth, height: plotHeight))
                        xAxisLabels(width: plotWidth)
                            .frame(height: Self.xAxisHeight)
                    }
                    yAxisLabels(height: plotHeight)
                        .frame(width: Self.yAxisWidth)
                }
            }
            .frame(height: WaveformSection.chartHeight)
        }
    }

    private var resolvedSubtitle: String {
        if let subtitleOverride { return subtitleOverride }
        if let unit, !unit.isEmpty { return "(\(unit))" }
        return ""
    }

    // MARK: Plot area

    @ViewBuilder
    private func plotArea(size: CGSize) -> some View {
        let math = CanvasAxesMath(
            visibleStart: axes.scrollBinding.wrappedValue,
            visibleLength: axes.visibleDomainLength,
            yDomain: yDomain,
            size: size
        )
        ZStack {
            // Grid lines live in a tiny Canvas overlay so they
            // render with the axes rather than on top of the
            // trace. Cheap to draw (4 horizontals + 6 verticals)
            // and survives the heavy trace Canvas's equatable
            // short-circuit because they share input state.
            Canvas(rendersAsynchronously: false) { context, canvasSize in
                drawGridLines(context: context, size: canvasSize, math: math)
            }
            .allowsHitTesting(false)

            // Main trace Canvas — flattened into a Metal texture
            // via `.drawingGroup()` so repaint cost is a texture
            // composite, not a re-stroke.
            Canvas(rendersAsynchronously: false) { context, canvasSize in
                draw(context, canvasSize, math)
            }
            .drawingGroup()
            .clipped()

            if let hoverOffset,
               let x = math.xPixel(for: hoverOffset),
               (0...size.width).contains(x) {
                // Dashed vertical hover rule. Lives outside the
                // trace Canvas so moving the probe doesn't force
                // a re-render of the expensive trace.
                dashedVerticalRule
                    .frame(width: 1, height: size.height)
                    .position(x: x, y: size.height / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture { location in
            guard let offset = math.dataOffset(forPixel: location.x) else { return }
            axes.hoverBinding.wrappedValue = offset
        }
        #if os(macOS)
        // macOS: drag a chart body to pan the zoom window. On iOS
        // this gesture is intentionally absent — even as a
        // `simultaneousGesture`, it defeats the enclosing sheet's
        // vertical scroll, forcing users to scroll only along the
        // side margins. Panning on iOS is done via the timeline
        // scrubber instead, which keeps the chart hit area purely
        // for tap-to-drop-probe and lets the ScrollView own vertical
        // drags.
        .simultaneousGesture(scrollGesture(width: size.width))
        #endif
    }

    private var dashedVerticalRule: some View {
        // Rectangle path filled with a dashed pattern by rendering
        // as a 1pt wide Rectangle with a dash via a shape. Simpler
        // to use a plain solid rule here — the previous SwiftUI-
        // Charts hover rule was dashed, but a thin solid line
        // reads cleaner at 1pt and survives snapshot scaling.
        Rectangle()
            .fill(Color.secondary.opacity(0.6))
    }

    // MARK: Gestures

    #if os(macOS)
    private func scrollGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard axes.isZoomed, width > 0 else { return }
                let secondsPerPoint = axes.visibleDomainLength / Double(width)
                let deltaSeconds = -Double(value.translation.width) * secondsPerPoint
                let target = axes.scrollBinding.wrappedValue + deltaSeconds
                let clamped = max(
                    0,
                    min(
                        axes.totalDuration - axes.visibleDomainLength,
                        target
                    )
                )
                axes.scrollBinding.wrappedValue = clamped
            }
    }
    #endif

    // MARK: Axes

    @ViewBuilder
    private func yAxisLabels(height: CGFloat) -> some View {
        let ticks = evenTicks(
            min: yDomain.lowerBound,
            max: yDomain.upperBound,
            count: 4
        )
        let math = CanvasAxesMath(
            visibleStart: axes.scrollBinding.wrappedValue,
            visibleLength: axes.visibleDomainLength,
            yDomain: yDomain,
            size: CGSize(width: Self.yAxisWidth, height: height)
        )
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(ticks.indices, id: \.self) { i in
                if let y = math.yPixel(for: ticks[i]) {
                    Text(formatY(ticks[i]))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: Self.yAxisWidth - 6, alignment: .leading)
                        .position(x: (Self.yAxisWidth - 6) / 2 + 6, y: y)
                }
            }
        }
    }

    @ViewBuilder
    private func xAxisLabels(width: CGFloat) -> some View {
        let start = axes.scrollBinding.wrappedValue
        let end = start + axes.visibleDomainLength
        let ticks = niceTimeTicks(start: start, end: end, dayStart: axes.dayStart)
        let math = CanvasAxesMath(
            visibleStart: start,
            visibleLength: axes.visibleDomainLength,
            yDomain: yDomain,
            size: CGSize(width: width, height: Self.xAxisHeight)
        )
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(ticks.indices, id: \.self) { i in
                if let x = math.xPixel(for: ticks[i]) {
                    Text(axes.clockLabel(ticks[i]))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: x, y: Self.xAxisHeight / 2)
                }
            }
        }
    }

    // MARK: Grid lines

    private func drawGridLines(
        context: GraphicsContext,
        size: CGSize,
        math: CanvasAxesMath
    ) {
        let gridColor = Color.secondary.opacity(0.18)
        let gridStyle = StrokeStyle(lineWidth: 0.5)

        let yTicks = evenTicks(
            min: yDomain.lowerBound,
            max: yDomain.upperBound,
            count: 4
        )
        for tick in yTicks {
            guard let y = math.yPixel(for: tick) else { continue }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(gridColor), style: gridStyle)
        }

        let xStart = axes.scrollBinding.wrappedValue
        let xEnd = xStart + axes.visibleDomainLength
        let xTicks = niceTimeTicks(start: xStart, end: xEnd, dayStart: axes.dayStart)
        for tick in xTicks {
            guard let x = math.xPixel(for: tick) else { continue }
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(gridColor), style: gridStyle)
        }
    }

    // MARK: Legend

    @ViewBuilder
    private func legendRow(_ entries: [CanvasLegendEntry]) -> some View {
        HStack(spacing: 10) {
            ForEach(entries, id: \.label) { entry in
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(entry.color)
                        .frame(width: 10, height: 2)
                    Text(entry.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Canvas math + drawing helpers

fileprivate struct CanvasAxesMath {
    let visibleStart: TimeInterval
    let visibleLength: TimeInterval
    let yDomain: ClosedRange<Double>
    let size: CGSize

    func xPixel(for offset: TimeInterval) -> CGFloat? {
        guard visibleLength > 0 else { return nil }
        let ratio = (offset - visibleStart) / visibleLength
        guard ratio.isFinite else { return nil }
        return CGFloat(ratio) * size.width
    }

    func yPixel(for value: Double) -> CGFloat? {
        let range = yDomain.upperBound - yDomain.lowerBound
        guard range > 0 else { return nil }
        let ratio = (value - yDomain.lowerBound) / range
        // Higher values render toward the top.
        return size.height - CGFloat(ratio) * size.height
    }

    func dataOffset(forPixel x: CGFloat) -> TimeInterval? {
        guard size.width > 0 else { return nil }
        let clamped = min(max(x, 0), size.width)
        let ratio = Double(clamped / size.width)
        return visibleStart + ratio * visibleLength
    }
}

/// Stroke one line series as a single Path per session. Stepped
/// mode inserts a horizontal lead between each point so value
/// changes look like discrete plateaus (matches how SwiftUI Charts
/// drew pressure / index signals).
fileprivate func strokeSeries(
    _ points: [FlatPoint],
    color: Color,
    lineWidth: CGFloat,
    stepped: Bool,
    in context: GraphicsContext,
    math: CanvasAxesMath
) {
    guard !points.isEmpty else { return }
    var currentSession: UUID?
    var path = Path()
    var lastPoint: CGPoint?
    for point in points {
        guard let x = math.xPixel(for: point.offset),
              let y = math.yPixel(for: point.value)
        else { continue }
        let p = CGPoint(x: x, y: y)
        if point.sessionID != currentSession {
            currentSession = point.sessionID
            path.move(to: p)
            lastPoint = p
        } else if stepped, let last = lastPoint {
            path.addLine(to: CGPoint(x: p.x, y: last.y))
            path.addLine(to: p)
            lastPoint = p
        } else {
            path.addLine(to: p)
            lastPoint = p
        }
    }
    context.stroke(
        path,
        with: .color(color),
        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    )
}

/// Fill the area under a line series with a vertical gradient —
/// `color` at the top of the plot fading to fully transparent at
/// `baselineY`. Classic "line chart with area wash" aesthetic: a
/// colour drop-off below each trace, lighter than a filled bar
/// chart and without obscuring overlapping lines when the opacity
/// ceiling is kept low. Handles both stepped and point-to-point
/// interpolation and closes each session's sub-path to the
/// baseline independently so gaps between sessions don't pick up
/// stray fill.
fileprivate func fillAreaBelow(
    _ points: [FlatPoint],
    color: Color,
    topOpacity: Double,
    stepped: Bool,
    baselineY: CGFloat,
    in context: GraphicsContext,
    math: CanvasAxesMath
) {
    guard !points.isEmpty else { return }
    var currentSession: UUID?
    var path = Path()
    var sessionStart: CGPoint?
    var lastPoint: CGPoint?

    func closeSession() {
        if let start = sessionStart, let last = lastPoint {
            path.addLine(to: CGPoint(x: last.x, y: baselineY))
            path.addLine(to: CGPoint(x: start.x, y: baselineY))
            path.closeSubpath()
        }
    }

    for point in points {
        guard let x = math.xPixel(for: point.offset),
              let y = math.yPixel(for: point.value)
        else { continue }
        let p = CGPoint(x: x, y: y)
        if point.sessionID != currentSession {
            closeSession()
            currentSession = point.sessionID
            path.move(to: CGPoint(x: p.x, y: baselineY))
            path.addLine(to: p)
            sessionStart = p
            lastPoint = p
        } else if stepped, let last = lastPoint {
            path.addLine(to: CGPoint(x: p.x, y: last.y))
            path.addLine(to: p)
            lastPoint = p
        } else {
            path.addLine(to: p)
            lastPoint = p
        }
    }
    closeSession()

    let shading: GraphicsContext.Shading = .linearGradient(
        Gradient(stops: [
            .init(color: color.opacity(topOpacity), location: 0),
            .init(color: color.opacity(0), location: 1)
        ]),
        startPoint: .zero,
        endPoint: CGPoint(x: 0, y: baselineY)
    )
    context.fill(path, with: shading)
}

/// Fill one area series as a single Path per session down to
/// `baselineY`. Stepped-only — the existing SignalAreaChart used
/// `.stepStart` so values read as discrete events.
fileprivate func fillSeries(
    _ points: [FlatPoint],
    color: Color,
    stepped: Bool,
    baselineY: CGFloat,
    in context: GraphicsContext,
    math: CanvasAxesMath
) {
    guard !points.isEmpty else { return }
    var currentSession: UUID?
    var path = Path()
    var sessionStart: CGPoint?
    var lastPoint: CGPoint?

    func closeSession() {
        if let start = sessionStart, let last = lastPoint {
            path.addLine(to: CGPoint(x: last.x, y: baselineY))
            path.addLine(to: CGPoint(x: start.x, y: baselineY))
            path.closeSubpath()
        }
    }

    for point in points {
        guard let x = math.xPixel(for: point.offset),
              let y = math.yPixel(for: point.value)
        else { continue }
        let p = CGPoint(x: x, y: y)
        if point.sessionID != currentSession {
            closeSession()
            currentSession = point.sessionID
            path.move(to: CGPoint(x: p.x, y: baselineY))
            path.addLine(to: p)
            sessionStart = p
            lastPoint = p
        } else if stepped, let last = lastPoint {
            path.addLine(to: CGPoint(x: p.x, y: last.y))
            path.addLine(to: p)
            lastPoint = p
        } else {
            path.addLine(to: p)
            lastPoint = p
        }
    }
    closeSession()
    context.fill(path, with: .color(color))
}

/// Shade the background behind each apnea / hypopnea event so the
/// trace reads against a coloured band at the event location.
fileprivate func drawEventRects(
    _ events: [TimedEvent],
    in context: GraphicsContext,
    size: CGSize,
    math: CanvasAxesMath
) {
    for event in events {
        guard let x0 = math.xPixel(for: event.offset),
              let x1 = math.xPixel(for: event.offset + event.duration)
        else { continue }
        let left = max(0, min(x0, x1))
        let right = min(size.width, max(x0, x1))
        guard right > left else { continue }
        let rect = CGRect(x: left, y: 0, width: right - left, height: size.height)
        context.fill(
            Path(rect),
            with: .color(ChartSubviewHelpers.eventColor(event.text).opacity(0.22))
        )
    }
}

/// Auto-fit Y range when no explicit domain is supplied. If
/// `symmetricZero` is true (used by the breathing chart), the
/// range is centered on zero — inhale / exhale stay balanced.
fileprivate func autoYDomain(
    _ points: [FlatPoint],
    symmetricZero: Bool,
    defaultMax: Double
) -> ClosedRange<Double> {
    guard !points.isEmpty else {
        return symmetricZero ? -defaultMax ... defaultMax : 0 ... defaultMax
    }
    var minV = Double.greatestFiniteMagnitude
    var maxV = -Double.greatestFiniteMagnitude
    var peakAbs: Double = 0
    for p in points {
        if p.value < minV { minV = p.value }
        if p.value > maxV { maxV = p.value }
        let a = Swift.abs(p.value)
        if a > peakAbs { peakAbs = a }
    }
    if symmetricZero {
        let padded = max(peakAbs * 1.1, 1)
        return -padded ... padded
    } else {
        let span = maxV - minV
        let pad = max(span * 0.1, 0.5)
        let low = minV - pad
        let high = maxV + pad
        return low ... high
    }
}

fileprivate func evenTicks(
    min lo: Double,
    max hi: Double,
    count: Int
) -> [Double] {
    guard count > 1, hi > lo else { return [lo] }
    let step = (hi - lo) / Double(count - 1)
    return (0..<count).map { lo + Double($0) * step }
}

/// X-axis ticks at rounded wall-clock times inside the visible window.
/// Mirrors what SwiftUI Charts' `.automatic(desiredCount:)` does for
/// `SessionTimelineView` above the canvas charts so the two axes agree
/// on which times to label — and keeps ticks interior so centered
/// labels don't spill past the plot edges.
fileprivate func niceTimeTicks(
    start: TimeInterval,
    end: TimeInterval,
    dayStart: Date
) -> [Double] {
    let range = end - start
    guard range > 0 else { return [] }

    // Step chosen to yield ~5-7 ticks across the visible range.
    let step: TimeInterval
    switch range {
    case ..<150:    step = 30       // 2m zoom → every 30s
    case ..<600:    step = 120      // 10m zoom → every 2m
    case ..<1500:   step = 300      // 30m zoom → every 5m
    case ..<3000:   step = 600      // 1h zoom → every 10m
    case ..<9000:   step = 1800     // a few hours → every 30m
    default:        step = 3600     // full night → hourly
    }

    let startDate = dayStart.addingTimeInterval(start)
    let localMidnight = Calendar.current.startOfDay(for: startDate)
    let secsIntoDay = startDate.timeIntervalSince(localMidnight)
    let firstRoundedSecs = (secsIntoDay / step).rounded(.up) * step
    let firstTickDate = localMidnight.addingTimeInterval(firstRoundedSecs)

    var ticks: [Double] = []
    var date = firstTickDate
    while date.timeIntervalSince(dayStart) <= end {
        ticks.append(date.timeIntervalSince(dayStart))
        date = date.addingTimeInterval(step)
    }
    return ticks
}

fileprivate func formatY(_ value: Double) -> String {
    if Swift.abs(value) < 10 { return String(format: "%.1f", value) }
    return String(format: "%.0f", value)
}
