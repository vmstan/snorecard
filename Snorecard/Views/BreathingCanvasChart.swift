import SwiftUI

/// Canvas-backed renderer for the Breathing waveform. Replaces the
/// SwiftUI-Charts `LineMark` ForEach with a single stroked `Path`
/// so dense flow data (several thousand points at a 10-minute zoom)
/// renders in one GPU draw call instead of thousands of diffable
/// marks. Preserves the visual contract of the old chart:
///
/// - Dashed red zero baseline
/// - Tinted event rectangles for apnea / hypopnea spans
/// - Per-session segments (no lines drawn across session gaps)
/// - Dashed vertical hover rule
/// - Y axis labels on the left, X clock labels across the bottom
///
/// Scroll is handled via a drag gesture that updates
/// `axes.scrollBinding`; hover is tracked via `.onContinuousHover`
/// so the rest of the chart stack sees hover changes just like the
/// SwiftUI-Charts path.
struct BreathingCanvasChart: View, Equatable {
    let unit: String
    let points: [FlatPoint]
    let events: [TimedEvent]
    let hoverOffset: TimeInterval?
    let axes: SharedAxisConfig

    nonisolated static func == (lhs: BreathingCanvasChart, rhs: BreathingCanvasChart) -> Bool {
        lhs.unit == rhs.unit
            && lhs.points.count == rhs.points.count
            && lhs.points.first?.offset == rhs.points.first?.offset
            && lhs.points.last?.offset == rhs.points.last?.offset
            && lhs.events.count == rhs.events.count
            && lhs.hoverOffset == rhs.hoverOffset
            && lhs.axes == rhs.axes
    }

    /// Y-axis labels match the SwiftUI Charts "33pt wide, trailing-
    /// aligned" convention so every waveform chart aligns vertically.
    private static let yAxisWidth: CGFloat = 33
    private static let xAxisHeight: CGFloat = 18

    private var visibleStart: TimeInterval { axes.scrollBinding.wrappedValue }
    private var visibleEnd: TimeInterval {
        axes.scrollBinding.wrappedValue + axes.visibleDomainLength
    }

    /// Symmetric auto-range around zero with a little headroom, so
    /// the zero line stays centered and inhale / exhale are balanced.
    private var yBounds: (min: Double, max: Double) {
        var peak: Double = 30
        for p in points {
            let abs = Swift.abs(p.value)
            if abs > peak { peak = abs }
        }
        let padded = peak * 1.1
        return (-padded, padded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChartSubviewTitle(title: "Breathing", subtitle: unit.isEmpty ? "" : "(\(unit))")
            chartBody
                .frame(height: WaveformSection.chartHeight)
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        GeometryReader { geo in
            let plotWidth = geo.size.width - Self.yAxisWidth
            let plotHeight = geo.size.height - Self.xAxisHeight
            HStack(spacing: 0) {
                yAxisLabels(height: plotHeight, bounds: yBounds)
                    .frame(width: Self.yAxisWidth)
                VStack(spacing: 0) {
                    plotArea(size: CGSize(width: plotWidth, height: plotHeight))
                    xAxisLabels(width: plotWidth)
                        .frame(height: Self.xAxisHeight)
                }
            }
        }
    }

    // MARK: - Plot area

    @ViewBuilder
    private func plotArea(size: CGSize) -> some View {
        let bounds = yBounds
        ZStack {
            Canvas(rendersAsynchronously: false) { context, canvasSize in
                draw(into: context, size: canvasSize, bounds: bounds)
            }
            .drawingGroup()
            .clipped()

            if let hoverOffset,
               let x = xPixel(for: hoverOffset, width: size.width),
               (0...size.width).contains(x) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 1, height: size.height)
                    .position(x: x, y: size.height / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if let offset = dataOffset(forPixel: location.x, width: size.width) {
                    axes.hoverBinding.wrappedValue = offset
                }
            case .ended:
                axes.hoverBinding.wrappedValue = nil
            }
        }
        .gesture(scrollGesture(width: size.width))
    }

    private func draw(
        into context: GraphicsContext,
        size: CGSize,
        bounds: (min: Double, max: Double)
    ) {
        // Zero baseline — dashed red, matches the previous chart.
        if let zeroY = yPixel(for: 0, height: size.height, bounds: bounds) {
            var zeroPath = Path()
            zeroPath.move(to: CGPoint(x: 0, y: zeroY))
            zeroPath.addLine(to: CGPoint(x: size.width, y: zeroY))
            context.stroke(
                zeroPath,
                with: .color(Color.red.opacity(0.7)),
                style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])
            )
        }

        // Event rectangles — dim background highlight behind the trace.
        for event in events {
            guard let x0 = xPixel(for: event.offset, width: size.width) else { continue }
            guard let x1 = xPixel(for: event.offset + event.duration, width: size.width) else { continue }
            let left = max(0, min(x0, x1))
            let right = min(size.width, max(x0, x1))
            guard right > left else { continue }
            let rect = CGRect(x: left, y: 0, width: right - left, height: size.height)
            context.fill(
                Path(rect),
                with: .color(ChartSubviewHelpers.eventColor(event.text).opacity(0.22))
            )
        }

        // Flow polyline, grouped by session so a gap between recordings
        // doesn't get a fake connecting segment. One stroked Path per
        // session keeps the GPU path count minimal.
        guard !points.isEmpty else { return }
        var currentSession: UUID?
        var path = Path()
        for point in points {
            guard let x = xPixel(for: point.offset, width: size.width),
                  let y = yPixel(for: point.value, height: size.height, bounds: bounds)
            else { continue }
            let p = CGPoint(x: x, y: y)
            if point.sessionID != currentSession {
                currentSession = point.sessionID
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }
        context.stroke(
            path,
            with: .color(.primary),
            style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Axes

    @ViewBuilder
    private func yAxisLabels(
        height: CGFloat,
        bounds: (min: Double, max: Double)
    ) -> some View {
        // 4-tick axis matching SharedAxesModifier's .automatic(desiredCount: 4).
        let ticks = evenTicks(min: bounds.min, max: bounds.max, count: 4)
        ZStack(alignment: .topTrailing) {
            Color.clear
            ForEach(ticks.indices, id: \.self) { i in
                let value = ticks[i]
                if let y = yPixel(for: value, height: height, bounds: bounds) {
                    Text(formatY(value))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: Self.yAxisWidth - 4, alignment: .trailing)
                        .position(x: (Self.yAxisWidth - 4) / 2, y: y)
                }
            }
        }
    }

    @ViewBuilder
    private func xAxisLabels(width: CGFloat) -> some View {
        // Six evenly-spaced labels spanning the visible time window.
        let ticks = evenTicks(
            min: visibleStart,
            max: visibleEnd,
            count: 6
        )
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(ticks.indices, id: \.self) { i in
                let offset = ticks[i]
                if let x = xPixel(for: offset, width: width) {
                    Text(axes.clockLabel(offset))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: x, y: Self.xAxisHeight / 2)
                }
            }
        }
    }

    // MARK: - Scroll / hover math

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
                // Incremental apply so the next onChanged reads the
                // current leading edge rather than the gesture's
                // cumulative translation.
                axes.scrollBinding.wrappedValue = clamped
            }
    }

    /// Convert a data-space time offset to a pixel x inside the plot
    /// area. Returns nil if the value falls outside the visible
    /// window.
    private func xPixel(for offset: TimeInterval, width: CGFloat) -> CGFloat? {
        let length = axes.visibleDomainLength
        guard length > 0 else { return nil }
        let ratio = (offset - visibleStart) / length
        guard ratio.isFinite else { return nil }
        return CGFloat(ratio) * width
    }

    private func yPixel(
        for value: Double,
        height: CGFloat,
        bounds: (min: Double, max: Double)
    ) -> CGFloat? {
        let range = bounds.max - bounds.min
        guard range > 0 else { return nil }
        let ratio = (value - bounds.min) / range
        // Flip — higher values render toward the top.
        return height - CGFloat(ratio) * height
    }

    private func dataOffset(forPixel x: CGFloat, width: CGFloat) -> TimeInterval? {
        guard width > 0 else { return nil }
        let ratio = Double(x / width)
        return visibleStart + ratio * axes.visibleDomainLength
    }

    /// Pick `count` evenly-spaced values between `min` and `max`,
    /// returning nice numbers where possible. This is the simple
    /// fallback — for L/min flow it's plenty.
    private func evenTicks(min lo: Double, max hi: Double, count: Int) -> [Double] {
        guard count > 1, hi > lo else { return [lo] }
        let step = (hi - lo) / Double(count - 1)
        return (0..<count).map { lo + Double($0) * step }
    }

    private func formatY(_ value: Double) -> String {
        if Swift.abs(value) < 10 { return String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }
}

/// `.equatable()` wrapper so SwiftUI short-circuits re-evaluation
/// when the chart's inputs haven't changed.
struct EquatableBreathingCanvasChart: View {
    let unit: String
    let points: [FlatPoint]
    let events: [TimedEvent]
    let hoverOffset: TimeInterval?
    let axes: SharedAxisConfig

    var body: some View {
        BreathingCanvasChart(
            unit: unit,
            points: points,
            events: events,
            hoverOffset: hoverOffset,
            axes: axes
        )
        .equatable()
    }
}
