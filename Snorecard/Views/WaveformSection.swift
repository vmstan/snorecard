import SwiftUI
import Charts
import SnorecardKit
import os.log

private let bundleLog = Logger(subsystem: "com.vmstan.Snorecard", category: "WaveformBundle")

/// Everything a day view needs to render its waveform and events, spanning all
/// sessions for the day on a single absolute-time axis.
struct WaveformBundle: Sendable {
    let dayStart: Date
    let totalDuration: TimeInterval
    let sessions: [SessionSegment]
    let events: [TimedEvent]
    /// Pre-flattened signal arrays so each chart can iterate with a single
    /// `ForEach` instead of nested session/point loops — the latter costs
    /// measurable rendering time on overnight datasets.
    let flatFlow: [FlatPoint]
    /// High-resolution min-max breath flow, ~50k points total. Used when
    /// the user zooms in; `flatFlow` stays the cheap overview-scale series.
    let flatFlowDetail: [FlatPoint]
    let flatPressure: [FlatPoint]
    let flatLeak: [FlatPoint]
    let flatRespRate: [FlatPoint]
    let flatTidalVolume: [FlatPoint]
    let flatMinuteVentilation: [FlatPoint]
    let flatSnore: [FlatPoint]
    let flatFlowLimitation: [FlatPoint]

    var isEmpty: Bool { sessions.isEmpty }

    static func load(
        brpFiles: [URL],
        pldFiles: [URL],
        eveFiles: [URL]
    ) throws -> WaveformBundle {
        bundleLog.info("WaveformBundle.load enter brp=\(brpFiles.count) pld=\(pldFiles.count) eve=\(eveFiles.count)")
        // Parse every file first so we can compute a shared day-start across sessions.
        let parsed = try brpFiles.compactMap { url -> ParsedBRP? in
            bundleLog.debug("reading BRP \(url.lastPathComponent, privacy: .public)")
            let file = try EDFFile(contentsOf: url)
            bundleLog.debug("decoded \(url.lastPathComponent, privacy: .public) records=\(file.header.recordCount)")
            guard file.header.recordCount > 0 else { return nil }
            return ParsedBRP(file: file, url: url)
        }
        bundleLog.info("WaveformBundle.load parsed \(parsed.count)/\(brpFiles.count) BRP files")
        guard let dayStart = parsed.map(\.file.header.startDate).min() else {
            return WaveformBundle(
                dayStart: Date(),
                totalDuration: 0,
                sessions: [],
                events: [],
                flatFlow: [],
                flatFlowDetail: [],
                flatPressure: [],
                flatLeak: [],
                flatRespRate: [],
                flatTidalVolume: [],
                flatMinuteVentilation: [],
                flatSnore: [],
                flatFlowLimitation: []
            )
        }

        // Build a time-indexed list of PLD files so each BRP can find its
        // nearest paired PLD. ResMed frequently writes the PLD 1 second after
        // the BRP for the same session, so an exact filename match misses
        // most sessions — we use a small tolerance instead.
        let pldByTime: [(time: Date, url: URL)] = pldFiles
            .compactMap { url in
                parseFilenameTimestamp(url).map { ($0, url) }
            }
            .sorted { $0.0 < $1.0 }

        func nearestPLD(to date: Date, tolerance: TimeInterval = 60) -> URL? {
            var best: (diff: TimeInterval, url: URL)?
            for entry in pldByTime {
                let diff = abs(entry.time.timeIntervalSince(date))
                if best == nil || diff < best!.diff {
                    best = (diff, entry.url)
                }
                if diff > (best?.diff ?? .infinity) { break }
            }
            guard let best, best.diff <= tolerance else { return nil }
            return best.url
        }

        var segments: [SessionSegment] = []
        var latestEnd: Date = dayStart

        for p in parsed {
            let file = p.file
            let sessionStart = file.header.startDate
            let duration = Double(file.header.recordCount) * file.header.recordDuration
            let sessionEnd = sessionStart.addingTimeInterval(duration)
            latestEnd = max(latestEnd, sessionEnd)
            let startOffset = sessionStart.timeIntervalSince(dayStart)

            let flowIdx = file.signals.firstIndex { $0.label.lowercased().hasPrefix("flow") } ?? 0
            let pressIdx = file.signals.firstIndex { $0.label.lowercased().hasPrefix("press") }
                ?? min(1, file.signals.count - 1)

            // ResMed stores flow in L/s; we present it in L/min to match
            // the convention used by OSCAR, SleepHQ, and clinical reports.
            let flowSamples = try file.physicalSamples(ofSignal: flowIdx).map { $0 * 60 }
            let pressSamples = try file.physicalSamples(ofSignal: pressIdx)

            let flowSig = file.signals[flowIdx]
            let pressSig = file.signals[pressIdx]
            let flowRate = Double(flowSig.samplesPerRecord) / file.header.recordDuration
            let pressRate = Double(pressSig.samplesPerRecord) / file.header.recordDuration

            // Two-tier flow downsampling: a small overview series for the
            // full-night fit view (cheap to render) and a high-resolution
            // min-max series used only when the user zooms in — at which
            // point we bin-slice down to just the visible window.
            let flowOverview = DownsampledSignal.points(
                samples: flowSamples,
                sampleRate: flowRate,
                startOffset: startOffset,
                targetPoints: 1500,
                style: .minMax
            )
            let flowDetail = DownsampledSignal.points(
                samples: flowSamples,
                sampleRate: flowRate,
                startOffset: startOffset,
                targetPoints: 50000,
                style: .minMax
            )
            let pressPoints = DownsampledSignal.points(
                samples: pressSamples,
                sampleRate: pressRate,
                startOffset: startOffset,
                targetPoints: 500
            )

            // Pair the BRP with its nearest PLD by filename timestamp and
            // decode every 0.5 Hz physiological signal we chart for this
            // session.
            var pld = PLDDecoded()
            if let brpTime = parseFilenameTimestamp(p.url),
               let pldURL = nearestPLD(to: brpTime),
               let pldFile = try? EDFFile(contentsOf: pldURL),
               pldFile.header.recordCount > 0 {
                pld = decodePLD(pldFile, startOffset: startOffset)
            }

            segments.append(
                SessionSegment(
                    id: UUID(),
                    startOffset: startOffset,
                    duration: duration,
                    flowLabel: flowSig.label,
                    flowUnit: "L/min",
                    pressureLabel: pressSig.label,
                    pressureUnit: pressSig.physicalDimension,
                    flow: flowOverview,
                    flowDetail: flowDetail,
                    pressure: pressPoints,
                    leak: pld.leak,
                    respirationRate: pld.respirationRate,
                    tidalVolume: pld.tidalVolume,
                    minuteVentilation: pld.minuteVentilation,
                    snore: pld.snore,
                    flowLimitation: pld.flowLimitation,
                    sourceFilename: p.url.lastPathComponent
                )
            )
        }

        // Decode events across every EVE file in the day and translate each
        // onset into an offset from the shared dayStart.
        var events: [TimedEvent] = []
        for url in eveFiles {
            let eve = try EDFFile(contentsOf: url)
            let eveStart = eve.header.startDate
            let eveOffset = eveStart.timeIntervalSince(dayStart)
            let raw = (try? eve.annotations()) ?? []
            for annotation in raw where !annotation.text.hasPrefix("Recording") {
                events.append(
                    TimedEvent(
                        offset: eveOffset + annotation.onset,
                        duration: max(annotation.duration ?? 0, 1),
                        text: annotation.text
                    )
                )
            }
        }

        let totalDuration = latestEnd.timeIntervalSince(dayStart)
        let sortedSessions = segments.sorted(by: { $0.startOffset < $1.startOffset })

        func flatten(_ keyPath: KeyPath<SessionSegment, [TimePoint]>) -> [FlatPoint] {
            var out: [FlatPoint] = []
            let capacity = sortedSessions.reduce(0) { $0 + $1[keyPath: keyPath].count }
            out.reserveCapacity(capacity)
            for session in sortedSessions {
                for point in session[keyPath: keyPath] {
                    out.append(FlatPoint(
                        offset: point.offset,
                        value: point.value,
                        sessionID: session.id
                    ))
                }
            }
            return out
        }

        return WaveformBundle(
            dayStart: dayStart,
            totalDuration: totalDuration,
            sessions: sortedSessions,
            events: events,
            flatFlow: flatten(\.flow),
            flatFlowDetail: flatten(\.flowDetail),
            flatPressure: flatten(\.pressure),
            flatLeak: flatten(\.leak),
            flatRespRate: flatten(\.respirationRate),
            flatTidalVolume: flatten(\.tidalVolume),
            flatMinuteVentilation: flatten(\.minuteVentilation),
            flatSnore: flatten(\.snore),
            flatFlowLimitation: flatten(\.flowLimitation)
        )
    }

    private struct ParsedBRP {
        let file: EDFFile
        let url: URL
    }
}

/// Decode the `YYYYMMDD_HHMMSS` timestamp embedded in a DATALOG filename.
/// Used to pair BRP ↔ PLD files — exact prefix matching fails when the
/// device writes the two files a second apart.
private func parseFilenameTimestamp(_ url: URL) -> Date? {
    let name = (url.lastPathComponent as NSString).deletingPathExtension
    let parts = name.split(separator: "_")
    guard parts.count >= 2,
          parts[0].count == 8,
          parts[1].count == 6 else { return nil }
    let d = parts[0]
    let t = parts[1]
    guard
        let year = Int(d.prefix(4)),
        let month = Int(d.dropFirst(4).prefix(2)),
        let day = Int(d.dropFirst(6).prefix(2)),
        let hour = Int(t.prefix(2)),
        let minute = Int(t.dropFirst(2).prefix(2)),
        let second = Int(t.dropFirst(4).prefix(2))
    else { return nil }
    return Calendar.current.date(from: DateComponents(
        year: year, month: month, day: day,
        hour: hour, minute: minute, second: second
    ))
}

/// Bundle of 0.5 Hz physiological signals decoded from a PLD file.
/// All arrays share the same time base, aligned to the session's shared-day
/// start offset. Downsampled to ~400 points per session for fast rendering.
private struct PLDDecoded {
    var leak: [TimePoint] = []
    var respirationRate: [TimePoint] = []
    var tidalVolume: [TimePoint] = []
    var minuteVentilation: [TimePoint] = []
    var snore: [TimePoint] = []
    var flowLimitation: [TimePoint] = []
}

private func decodePLD(
    _ pld: EDFFile,
    startOffset: TimeInterval
) -> PLDDecoded {
    var out = PLDDecoded()

    func points(
        prefix: String,
        scale: Double = 1
    ) -> [TimePoint] {
        guard let idx = pld.signals.firstIndex(where: { $0.label.hasPrefix(prefix) }),
              let samples = try? pld.physicalSamples(ofSignal: idx) else {
            return []
        }
        let signal = pld.signals[idx]
        let rate = Double(signal.samplesPerRecord) / pld.header.recordDuration
        guard rate > 0 else { return [] }
        let scaled = scale == 1 ? samples : samples.map { $0 * scale }
        return DownsampledSignal.points(
            samples: scaled,
            sampleRate: rate,
            startOffset: startOffset,
            targetPoints: 400
        )
    }

    // Leak is stored in L/s; every viewer shows L/min so we scale on decode.
    out.leak = points(prefix: "Leak", scale: 60)
    out.respirationRate = points(prefix: "RespRate")
    out.tidalVolume = points(prefix: "TidVol")
    out.minuteVentilation = points(prefix: "MinVent")
    out.snore = points(prefix: "Snore")
    out.flowLimitation = points(prefix: "FlowLim")
    return out
}

struct SessionSegment: Sendable, Identifiable {
    let id: UUID
    let startOffset: TimeInterval
    let duration: TimeInterval
    let flowLabel: String
    let flowUnit: String
    let pressureLabel: String
    let pressureUnit: String
    /// Overview-resolution flow samples (cheap to render, used at fit zoom).
    let flow: [TimePoint]
    /// High-resolution min-max flow samples used when zoomed in.
    let flowDetail: [TimePoint]
    let pressure: [TimePoint]
    /// 0.5 Hz signals from the paired PLD file. All empty when no PLD exists.
    let leak: [TimePoint]            // L/min (converted from L/s on decode)
    let respirationRate: [TimePoint] // bpm
    let tidalVolume: [TimePoint]     // L
    let minuteVentilation: [TimePoint] // L/min
    let snore: [TimePoint]           // 0–5 scale
    let flowLimitation: [TimePoint]  // 0–1 scale
    let sourceFilename: String
}

struct TimePoint: Sendable, Hashable {
    let offset: TimeInterval
    let value: Double
}

/// A single sample tagged with its owning session so charts can iterate the
/// full day's data with one `ForEach` while still breaking line continuity
/// at session boundaries via `series:`.
struct FlatPoint: Sendable, Hashable, Identifiable {
    let offset: TimeInterval
    let value: Double
    let sessionID: UUID
    /// Offset is unique within a signal (sessions never overlap in time), so
    /// it doubles as the row identity for `ForEach`.
    var id: Double { offset }
}

struct TimedEvent: Sendable, Hashable {
    let offset: TimeInterval
    let duration: TimeInterval
    let text: String
}

enum DownsampleStyle {
    /// One sample per bucket — the one with the largest absolute value.
    /// Fine for near-monotonic signals (pressure, leak) where only the
    /// peak matters.
    case peakAbsolute
    /// Two samples per bucket — both the min and the max, emitted in
    /// chronological order. Preserves the visual envelope of oscillating
    /// signals (like breath flow) at any downsample rate.
    case minMax
}

enum DownsampledSignal {
    static func points(
        samples: [Double],
        sampleRate: Double,
        startOffset: TimeInterval,
        targetPoints: Int,
        style: DownsampleStyle = .peakAbsolute
    ) -> [TimePoint] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }

        switch style {
        case .peakAbsolute:
            let bucket = max(1, samples.count / targetPoints)
            var out: [TimePoint] = []
            out.reserveCapacity(samples.count / bucket + 1)
            var i = 0
            while i < samples.count {
                let end = min(i + bucket, samples.count)
                var picked = samples[i]
                var maxAbs: Double = 0
                for j in i..<end {
                    let v = samples[j]
                    let a = abs(v)
                    if a > maxAbs {
                        maxAbs = a
                        picked = v
                    }
                }
                let time = startOffset + Double(i) / sampleRate
                out.append(TimePoint(offset: time, value: picked))
                i = end
            }
            return out

        case .minMax:
            // Each bucket emits two points (min and max) so the target
            // count is split in half to keep the total around the caller's
            // requested size.
            let effectiveBuckets = max(1, targetPoints / 2)
            let bucket = max(1, samples.count / effectiveBuckets)
            var out: [TimePoint] = []
            out.reserveCapacity((samples.count / bucket) * 2 + 2)
            var i = 0
            while i < samples.count {
                let end = min(i + bucket, samples.count)
                var minV = samples[i], minIdx = i
                var maxV = samples[i], maxIdx = i
                for j in (i + 1)..<end {
                    let v = samples[j]
                    if v < minV { minV = v; minIdx = j }
                    if v > maxV { maxV = v; maxIdx = j }
                }
                // Emit in chronological order so the connecting line
                // traces the envelope correctly.
                if minIdx <= maxIdx {
                    out.append(TimePoint(
                        offset: startOffset + Double(minIdx) / sampleRate,
                        value: minV
                    ))
                    if minIdx != maxIdx {
                        out.append(TimePoint(
                            offset: startOffset + Double(maxIdx) / sampleRate,
                            value: maxV
                        ))
                    }
                } else {
                    out.append(TimePoint(
                        offset: startOffset + Double(maxIdx) / sampleRate,
                        value: maxV
                    ))
                    out.append(TimePoint(
                        offset: startOffset + Double(minIdx) / sampleRate,
                        value: minV
                    ))
                }
                i = end
            }
            return out
        }
    }
}

struct WaveformSection: View {
    let bundle: WaveformBundle
    @State private var hoverOffset: TimeInterval?
    /// Width of the visible x-axis window in seconds. `0` means "fit the
    /// whole night" and the charts show their full domain.
    @State private var zoomWindow: TimeInterval = 0
    /// Leading edge of the visible window (offset from `bundle.dayStart`).
    @State private var scrollPosition: TimeInterval = 0
    /// Visible-window length snapshot captured at the start of a pinch
    /// gesture so mid-gesture magnification is applied relative to it.
    @State private var pinchBaseWindow: TimeInterval?
    /// Data-offset the pinch should stay anchored on — either the hover
    /// position when the gesture began, or the centre of the viewport.
    @State private var pinchAnchorOffset: TimeInterval?

    private var visibleDomainLength: TimeInterval {
        zoomWindow > 0 ? min(zoomWindow, max(bundle.totalDuration, 1)) : max(bundle.totalDuration, 1)
    }

    private var isZoomed: Bool {
        zoomWindow > 0 && zoomWindow < bundle.totalDuration
    }

    /// Flow samples for the current zoom state. At "fit" we use the cheap
    /// 1,500-point overview. At any zoom we binary-slice the 50k-point
    /// detail array to just the visible window (plus a generous margin
    /// so small scroll nudges don't re-slice on every frame). This keeps
    /// the Chart's `ForEach` fed with at most a few thousand marks.
    private var visibleFlowPoints: [FlatPoint] {
        guard isZoomed else { return bundle.flatFlow }

        let margin = visibleDomainLength
        let lo = max(0, scrollPosition - margin)
        let hi = scrollPosition + visibleDomainLength + margin

        let source = bundle.flatFlowDetail
        guard !source.isEmpty else { return [] }

        let start = source.lowerBound(where: { $0.offset >= lo })
        let end = source.lowerBound(where: { $0.offset > hi })
        guard start < end else { return [] }
        return Array(source[start..<end])
    }

    private var flowUnit: String { bundle.sessions.first?.flowUnit ?? "" }
    private var pressureUnit: String { bundle.sessions.first?.pressureUnit ?? "" }
    private var hasLeak: Bool { !bundle.flatLeak.isEmpty }
    private var hasTidalVolume: Bool { !bundle.flatTidalVolume.isEmpty }
    private var hasSnore: Bool { !bundle.flatSnore.isEmpty }
    private var hasFlowLim: Bool { !bundle.flatFlowLimitation.isEmpty }

    var body: some View {
        content
            .simultaneousGesture(magnifyGesture)
            .background(keyboardShortcuts)
    }

    @ViewBuilder
    private var keyboardShortcuts: some View {
        Group {
            Button("Zoom In") { zoomBy(factor: 0.5) }
                .keyboardShortcut(KeyEquivalent("="), modifiers: .command)
            Button("Zoom Out") { zoomBy(factor: 2.0) }
                .keyboardShortcut(KeyEquivalent("-"), modifiers: .command)
            Button("Fit") { applyZoom(seconds: 0) }
                .keyboardShortcut(KeyEquivalent("0"), modifiers: .command)
            Button("Pan Left") { panBy(fraction: -0.25) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Pan Right") { panBy(fraction: 0.25) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
        }
        .hidden()
    }

    private func panBy(fraction: Double) {
        guard isZoomed else { return }
        let delta = visibleDomainLength * fraction
        var newStart = scrollPosition + delta
        newStart = max(0, min(newStart, max(0, bundle.totalDuration - visibleDomainLength)))
        withAnimation(.easeOut(duration: 0.15)) {
            scrollPosition = newStart
        }
    }

    private func zoomBy(factor: Double) {
        let current = visibleDomainLength
        let newWindow = max(10, min(current * factor, max(bundle.totalDuration, 10)))
        let anchor = hoverOffset ?? (scrollPosition + current / 2)
        var newStart = anchor - newWindow / 2
        newStart = max(0, min(newStart, max(0, bundle.totalDuration - newWindow)))
        withAnimation(.easeOut(duration: 0.15)) {
            zoomWindow = newWindow >= bundle.totalDuration ? 0 : newWindow
            scrollPosition = newStart
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            hoverReadout

            if bundle.isEmpty {
                ContentUnavailableView(
                    "No session data",
                    systemImage: "moon.zzz",
                    description: Text("This day has no complete sessions.")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                SessionTimelineView(
                    bundle: bundle,
                    onJumpToTime: { time in jumpTo(time: time) },
                    viewportStart: scrollPosition,
                    viewportLength: isZoomed ? visibleDomainLength : 0
                )
                zoomControls

                lineChart(
                    title: "Breathing",
                    unit: flowUnit,
                    points: visibleFlowPoints,
                    color: .primary,
                    overlayEvents: true,
                    zeroReference: true
                )
                lineChart(
                    title: "Pressure",
                    unit: pressureUnit,
                    points: bundle.flatPressure,
                    color: .purple,
                    overlayEvents: false,
                    stepped: true
                )
                if hasLeak {
                    lineChart(
                        title: "Leak",
                        unit: "L/min",
                        points: bundle.flatLeak,
                        color: .yellow,
                        overlayEvents: false,
                        thresholdY: 24
                    )
                }
                if hasFlowLim {
                    areaChart(
                        title: "Flow Limitation",
                        subtitle: "index (0–1)",
                        points: bundle.flatFlowLimitation,
                        color: .pink,
                        yDomain: 0...1
                    )
                }
                if hasTidalVolume {
                    lineChart(
                        title: "Tidal Volume",
                        unit: "L",
                        points: bundle.flatTidalVolume,
                        color: .indigo,
                        overlayEvents: false
                    )
                }
                if hasSnore {
                    areaChart(
                        title: "Snore",
                        subtitle: "index (0–5)",
                        points: bundle.flatSnore,
                        color: .green,
                        yDomain: 0...5
                    )
                }
            }
        }
    }

    /// Live value readout that follows the hover position across all charts.
    /// Chips wrap to a second row when the main chart pane isn't wide enough
    /// to hold all active signals in one line.
    @ViewBuilder
    private var hoverReadout: some View {
        let time = hoverOffset.map { bundle.dayStart.addingTimeInterval($0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(time?.formatted(date: .omitted, time: .shortened) ?? "—")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .frame(minWidth: 60, alignment: .leading)
                Spacer(minLength: 0)
            }
            FlowLayout(horizontalSpacing: 16, verticalSpacing: 6) {
                readoutChip(
                    "Breathing",
                    value: hoverValue(isZoomed ? bundle.flatFlowDetail : bundle.flatFlow),
                    unit: flowUnit,
                    format: "%.1f",
                    color: .primary
                )
                readoutChip(
                    "Pressure",
                    value: hoverValue(bundle.flatPressure),
                    unit: pressureUnit,
                    format: "%.1f",
                    color: .purple
                )
                if hasLeak {
                    readoutChip(
                        "Leak",
                        value: hoverValue(bundle.flatLeak),
                        unit: "L/min",
                        format: "%.0f",
                        color: .yellow
                    )
                }
                if hasFlowLim {
                    readoutChip(
                        "Flow Limitation",
                        value: hoverValue(bundle.flatFlowLimitation),
                        unit: "",
                        format: "%.2f",
                        color: .pink
                    )
                }
                if hasTidalVolume {
                    readoutChip(
                        "Tidal Volume",
                        value: hoverValue(bundle.flatTidalVolume),
                        unit: "L",
                        format: "%.2f",
                        color: .indigo
                    )
                }
                if hasSnore {
                    readoutChip(
                        "Snore",
                        value: hoverValue(bundle.flatSnore),
                        unit: "",
                        format: "%.1f",
                        color: .green
                    )
                }
            }
        }
        .padding(10)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func readoutChip(
        _ label: String,
        value: Double?,
        unit: String,
        format: String,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value.map { String(format: format, $0) } ?? "—")
                .font(.callout.monospacedDigit())
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Nearest sample in a flat signal array to the current hover offset.
    /// Flat arrays are sorted by offset, so a single binary search finds
    /// the neighbour in O(log n).
    private func hoverValue(_ points: [FlatPoint]) -> Double? {
        guard let target = hoverOffset, !points.isEmpty else { return nil }
        var lo = 0
        var hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].offset < target { lo = mid + 1 } else { hi = mid }
        }
        var best = points[lo]
        if lo > 0 {
            let prev = points[lo - 1]
            if abs(prev.offset - target) < abs(best.offset - target) {
                best = prev
            }
        }
        // Snap only if we're actually within session coverage.
        guard abs(best.offset - target) < 60 else { return nil }
        return best.value
    }

    private static let chartHeight: CGFloat = 140

    /// Preset zoom windows in seconds. `0` means "fit the whole night".
    private static let zoomPresets: [(label: String, seconds: TimeInterval)] = [
        ("Fit", 0),
        ("1h", 3600),
        ("30m", 1800),
        ("10m", 600),
        ("2m", 120),
        ("30s", 30)
    ]

    @ViewBuilder
    private var zoomControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                Button {
                    jumpToEvent(direction: .previous)
                } label: {
                    Image(systemName: "chevron.left.circle")
                }
                .buttonStyle(.bordered)
                .disabled(bundle.events.isEmpty)
                .help("Previous event (⌘⇧[)")
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button {
                    jumpToEvent(direction: .next)
                } label: {
                    Image(systemName: "chevron.right.circle")
                }
                .buttonStyle(.bordered)
                .disabled(bundle.events.isEmpty)
                .help("Next event (⌘⇧])")
                .keyboardShortcut("]", modifiers: [.command, .shift])

                ForEach(Self.zoomPresets, id: \.label) { preset in
                    Button {
                        applyZoom(seconds: preset.seconds)
                    } label: {
                        Text(preset.label)
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(isCurrentPreset(preset.seconds) ? Color.accentColor : Color.secondary)
                }
            }
            if isZoomed {
                Text(zoomRangeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, Self.plotAreaLeadingInset)
    }

    private enum EventJumpDirection { case next, previous }

    private func jumpToEvent(direction: EventJumpDirection) {
        guard !bundle.events.isEmpty else { return }
        let sorted = bundle.events.sorted { $0.offset < $1.offset }
        let center = scrollPosition + visibleDomainLength / 2
        let target: TimedEvent?
        switch direction {
        case .next:
            target = sorted.first { $0.offset > center + 0.5 } ?? sorted.first
        case .previous:
            target = sorted.last { $0.offset < center - 0.5 } ?? sorted.last
        }
        guard let target else { return }
        jumpTo(time: target.offset)
    }

    /// Pinch / magnify gesture that rescales `zoomWindow` around the
    /// current anchor (hover offset when available, otherwise the centre
    /// of the visible window). Clamped to a minimum of 10 s and a maximum
    /// of the full day.
    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if pinchBaseWindow == nil {
                    pinchBaseWindow = visibleDomainLength
                    pinchAnchorOffset = hoverOffset
                        ?? (scrollPosition + visibleDomainLength / 2)
                }
                guard
                    let baseWindow = pinchBaseWindow,
                    let anchor = pinchAnchorOffset
                else { return }

                let magnification = max(0.1, value.magnification)
                let newWindow = baseWindow / magnification
                let clamped = max(10, min(newWindow, max(bundle.totalDuration, 10)))

                zoomWindow = clamped >= bundle.totalDuration ? 0 : clamped
                let effectiveWindow = visibleDomainLength
                var newStart = anchor - effectiveWindow / 2
                newStart = max(0, min(newStart, max(0, bundle.totalDuration - effectiveWindow)))
                scrollPosition = newStart
            }
            .onEnded { _ in
                pinchBaseWindow = nil
                pinchAnchorOffset = nil
            }
    }

    /// Recenter the visible window on `time`. When the chart is currently
    /// in Fit mode, also zooms to a reasonable default window (10 minutes)
    /// so the click actually reveals detail.
    private func jumpTo(time: TimeInterval) {
        let window: TimeInterval
        if zoomWindow > 0 {
            window = zoomWindow
        } else {
            window = min(600, max(bundle.totalDuration, 1))
        }
        let clamped = min(window, max(bundle.totalDuration, 1))
        var newStart = time - clamped / 2
        newStart = max(0, min(newStart, max(0, bundle.totalDuration - clamped)))
        withAnimation(.easeOut(duration: 0.2)) {
            zoomWindow = clamped
            scrollPosition = newStart
        }
    }

    private func applyZoom(seconds: TimeInterval) {
        if seconds == 0 {
            zoomWindow = 0
            scrollPosition = 0
            return
        }
        let clamped = min(seconds, max(bundle.totalDuration, 1))
        // Anchor the new window around the current hover offset when
        // available, otherwise around the centre of the existing window.
        let anchor = hoverOffset
            ?? (scrollPosition + visibleDomainLength / 2)
        var newStart = anchor - clamped / 2
        newStart = max(0, min(newStart, max(0, bundle.totalDuration - clamped)))
        zoomWindow = clamped
        scrollPosition = newStart
    }

    private func isCurrentPreset(_ seconds: TimeInterval) -> Bool {
        if seconds == 0 {
            return zoomWindow == 0
        }
        return abs(zoomWindow - seconds) < 1
    }

    private var zoomRangeLabel: String {
        let start = bundle.dayStart.addingTimeInterval(scrollPosition)
        let end = bundle.dayStart.addingTimeInterval(scrollPosition + visibleDomainLength)
        let startStr = start.formatted(date: .omitted, time: .shortened)
        let endStr = end.formatted(date: .omitted, time: .shortened)
        return "\(startStr) – \(endStr)"
    }

    /// Visual style for a per-sample chart.
    /// `.line` connects the samples across the session (normal line chart).
    /// `.bars` draws each sample as a thin vertical stem from the zero
    /// baseline, matching the dense "hairy" flow waveform style used by
    /// OSCAR / SleepHQ / ResScan.
    enum PointChartStyle {
        case line
        case bars
    }

    @ViewBuilder
    private func lineChart(
        title: String,
        unit: String,
        points: [FlatPoint],
        color: Color,
        overlayEvents: Bool,
        zeroReference: Bool = false,
        stepped: Bool = false,
        thresholdY: Double? = nil,
        style: PointChartStyle = .line
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            chartTitle(title, subtitle: unit.isEmpty ? "" : "(\(unit))")
            Chart {
                if zeroReference {
                    // Dashed red zero baseline to match OSCAR / SleepHQ
                    // convention for breath flow charts — makes
                    // inhale-vs-exhale direction unambiguous.
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(Color.red.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }

                if let thresholdY {
                    RuleMark(y: .value("Threshold", thresholdY))
                        .foregroundStyle(Color.red.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }

                ForEach(points) { point in
                    switch style {
                    case .bars:
                        // Stem-plot style: a thin vertical bar from y=0
                        // to the sample value. BarMark with a continuous
                        // x axis renders one narrow bar per point, which
                        // gives the dense flow-waveform look.
                        BarMark(
                            x: .value("Time", point.offset),
                            yStart: .value("Zero", 0),
                            yEnd: .value(title, point.value),
                            width: .fixed(0.8)
                        )
                        .foregroundStyle(color)

                    case .line:
                        let mark = LineMark(
                            x: .value("Time", point.offset),
                            y: .value(title, point.value),
                            series: .value("Session", point.sessionID.uuidString)
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1))

                        if stepped {
                            mark.interpolationMethod(.stepEnd)
                        } else {
                            mark
                        }
                    }
                }

                if overlayEvents {
                    ForEach(Array(bundle.events.enumerated()), id: \.offset) { _, event in
                        RectangleMark(
                            xStart: .value("Start", event.offset),
                            xEnd: .value("End", event.offset + event.duration)
                        )
                        .foregroundStyle(eventColor(event.text).opacity(0.22))
                    }
                }

                if let hoverOffset {
                    RuleMark(x: .value("Hover", hoverOffset))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .modifier(SharedAxesModifier(
                bundle: bundle,
                clockLabel: clockLabel(for:)
            ))
            .chartXVisibleDomain(length: visibleDomainLength)
            .chartScrollableAxes(isZoomed ? .horizontal : [])
            .chartScrollPosition(x: $scrollPosition)
            .chartXSelection(value: $hoverOffset)
            .frame(height: Self.chartHeight)
        }
    }

    @ViewBuilder
    private func areaChart(
        title: String,
        subtitle: String,
        points: [FlatPoint],
        color: Color,
        yDomain: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            chartTitle(title, subtitle: subtitle)
            Chart {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Time", point.offset),
                        y: .value(title, point.value),
                        series: .value("Session", point.sessionID.uuidString)
                    )
                    .foregroundStyle(color.opacity(0.55))
                    .interpolationMethod(.stepStart)
                }
                if let hoverOffset {
                    RuleMark(x: .value("Hover", hoverOffset))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: yDomain)
            .modifier(SharedAxesModifier(
                bundle: bundle,
                clockLabel: clockLabel(for:)
            ))
            .chartXVisibleDomain(length: visibleDomainLength)
            .chartScrollableAxes(isZoomed ? .horizontal : [])
            .chartScrollPosition(x: $scrollPosition)
            .chartXSelection(value: $hoverOffset)
            .frame(height: Self.chartHeight)
        }
    }

    /// Y-axis label column width (32) + a small gap so chart headers line
    /// up with where the plot area actually starts.
    private static let plotAreaLeadingInset: CGFloat = 40

    @ViewBuilder
    private func chartTitle(_ title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, Self.plotAreaLeadingInset)
    }

    private func clockLabel(for offset: TimeInterval) -> String {
        let date = bundle.dayStart.addingTimeInterval(offset)
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func eventColor(_ text: String) -> Color {
        let lower = text.lowercased()
        if lower.contains("obstructive") { return .red }
        if lower.contains("central") { return .purple }
        if lower.contains("hypopnea") { return .yellow }
        return .gray
    }
}

extension Array {
    /// Binary search for the first index where `predicate` is true,
    /// assuming the array is partitioned such that all `false` values
    /// come before all `true` values. Returns `count` if no such index
    /// exists.
    fileprivate func lowerBound(where predicate: (Element) -> Bool) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(self[mid]) {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo
    }
}

/// Applies the shared X/Y axis treatment to every waveform chart so tick
/// placement and, crucially, plot-area width line up across the vertical
/// stack. Fixed-width Y-axis labels make the left edge of every chart
/// identical regardless of numeric value width.
private struct SharedAxesModifier: ViewModifier {
    let bundle: WaveformBundle
    let clockLabel: (TimeInterval) -> String

    func body(content: Content) -> some View {
        content
            .chartLegend(.hidden)
            .chartXScale(domain: 0 ... max(bundle.totalDuration, 1))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    if let seconds = value.as(Double.self) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            Text(clockLabel(seconds))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(anchor: .trailing) {
                        if let v = value.as(Double.self) {
                            Text(Self.format(v))
                                .font(.caption2.monospacedDigit())
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
            }
    }

    /// Pick a format that keeps the Y-axis label column visually tidy across
    /// charts with very different value magnitudes (flow in fractions of
    /// L/s vs pressure in whole cmH₂O).
    private static func format(_ value: Double) -> String {
        if abs(value) < 10 { return String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }
}

