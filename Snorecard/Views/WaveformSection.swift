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
    /// Mid-density breath flow used at 30m / 1h zooms — trades some
    /// detail for a lighter render than `flatFlowDetail`.
    let flatFlowMid: [FlatPoint]
    /// Near-native breath flow used at tight zooms (≤ 10m).
    let flatFlowDetail: [FlatPoint]
    let flatPressure: [FlatPoint]
    let flatLeak: [FlatPoint]
    let flatRespRate: [FlatPoint]
    let flatTidalVolume: [FlatPoint]
    let flatMinuteVentilation: [FlatPoint]
    let flatSnore: [FlatPoint]
    let flatFlowLimitation: [FlatPoint]
    let flatIPAP: [FlatPoint]
    let flatEPAP: [FlatPoint]
    /// Min / median / 95% / 99.5% summary table for the night,
    /// computed from raw PLD samples (not the downsampled chart
    /// arrays) so the percentiles are clinically accurate.
    let signalSummary: [SignalSummaryRow]

    var isEmpty: Bool { sessions.isEmpty }

    /// One row of the per-night signal-summary table — min /
    /// median / 95% / 99.5% percentiles for a single PLD signal.
    /// `format` returns the value already converted to the user-
    /// facing display string (e.g. "16.24" or "600 mL"); the
    /// table renderer reads `display*` directly.
    ///
    /// Hashable + Codable so the row can travel through SwiftUI's
    /// `openWindow(value:)` API when the table opens in its own
    /// macOS window.
    struct SignalSummaryRow: Sendable, Identifiable, Hashable, Codable {
        let id: String
        let label: String
        let unit: String
        let displayMin: String
        let displayMedian: String
        let displayP95: String
        let displayP99_5: String
    }

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
                flatFlowMid: [],
                flatFlowDetail: [],
                flatPressure: [],
                flatLeak: [],
                flatRespRate: [],
                flatTidalVolume: [],
                flatMinuteVentilation: [],
                flatSnore: [],
                flatFlowLimitation: [],
                flatIPAP: [],
                flatEPAP: [],
                signalSummary: []
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
        // Aggregate raw PLD samples across every session so the
        // summary table's percentiles reflect the full night.
        var rawAcrossSessions: [String: [Double]] = [:]

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

            // Three-tier flow downsampling. Canvas rendering lets
            // every tier carry a lot more points than the SwiftUI
            // Charts LineMark budget permitted — the GPU strokes a
            // single Path per session, so even the fit view can
            // carry several points per breath without stutter.
            //   * Overview  — ~1 point/sec on an 8h night.
            //   * Mid       — roughly halfway between overview and
            //                 native; covers 30m / 1h zooms.
            //   * Detail    — essentially native 25 Hz flow, crisp
            //                 at any zoom ≤ 2m.
            let flowOverview = DownsampledSignal.points(
                samples: flowSamples,
                sampleRate: flowRate,
                startOffset: startOffset,
                targetPoints: 30_000,
                style: .minMax
            )
            let flowMid = DownsampledSignal.points(
                samples: flowSamples,
                sampleRate: flowRate,
                startOffset: startOffset,
                targetPoints: 150_000,
                style: .minMax
            )
            let flowDetail = DownsampledSignal.points(
                samples: flowSamples,
                sampleRate: flowRate,
                startOffset: startOffset,
                targetPoints: 750_000,
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
                for (key, samples) in pld.rawSamples {
                    rawAcrossSessions[key, default: []].append(contentsOf: samples)
                }
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
                    flowMid: flowMid,
                    flowDetail: flowDetail,
                    pressure: pressPoints,
                    leak: pld.leak,
                    respirationRate: pld.respirationRate,
                    tidalVolume: pld.tidalVolume,
                    minuteVentilation: pld.minuteVentilation,
                    snore: pld.snore,
                    flowLimitation: pld.flowLimitation,
                    ipap: pld.ipap,
                    epap: pld.epap,
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

        let summary = Self.computeSignalSummary(rawByPrefix: rawAcrossSessions)

        return WaveformBundle(
            dayStart: dayStart,
            totalDuration: totalDuration,
            sessions: sortedSessions,
            events: events,
            flatFlow: flatten(\.flow),
            flatFlowMid: flatten(\.flowMid),
            flatFlowDetail: flatten(\.flowDetail),
            flatPressure: flatten(\.pressure),
            flatLeak: flatten(\.leak),
            flatRespRate: flatten(\.respirationRate),
            flatTidalVolume: flatten(\.tidalVolume),
            flatMinuteVentilation: flatten(\.minuteVentilation),
            flatSnore: flatten(\.snore),
            flatFlowLimitation: flatten(\.flowLimitation),
            flatIPAP: flatten(\.ipap),
            flatEPAP: flatten(\.epap),
            signalSummary: summary
        )
    }

    /// Build the per-night signal summary table. Each entry pairs
    /// a PLD-signal prefix to a display label + unit + value
    /// formatter, then computes min / median / 95% / 99.5% from
    /// the aggregated raw samples. Signals missing from this
    /// device are silently skipped.
    private static func computeSignalSummary(
        rawByPrefix: [String: [Double]]
    ) -> [SignalSummaryRow] {
        // Mask-pressure samples gate "on therapy" — anything below
        // 1 cmH₂O is the user not wearing the mask, and including
        // those in the percentile would skew the table toward 0.
        let mask = rawByPrefix["MaskPress"] ?? []
        let onTherapyMask: [Bool] = mask.map { $0 > 1.0 }
        // If we never saw a mask-press signal, fall back to "all
        // samples are on-therapy" so the table still renders.
        let useMaskFilter = !onTherapyMask.isEmpty

        struct SpecEntry {
            /// Candidate prefixes, tried in order. ResMed firmwares
            /// disagree on naming (`Ti.2s` vs `Ti`, `RespEvt.2s` vs
            /// `RespEvent`, …) so each logical row can source from
            /// any of a small set. First non-empty one wins.
            let prefixes: [String]
            let label: String
            let unit: String
            let scale: Double
            let format: (Double) -> String
        }

        let pressureFmt: (Double) -> String = { String(format: "%.2f", $0) }
        let oneDecimalFmt: (Double) -> String = { String(format: "%.1f", $0) }
        let twoDecimalFmt: (Double) -> String = { String(format: "%.2f", $0) }
        let intFmt: (Double) -> String = { String(format: "%.0f", $0) }

        // Order mirrors the waveform charts below the table:
        // Pressure (IPAP+EPAP) → Leak → Flow Limit → Tidal Volume
        // → Snore. The breath-timing and respiratory-event signals
        // tail the list because nothing charts them.
        //
        // The trailing dot on `Ti.` / `Te.` stops the prefix from
        // matching `TidVol.*` or other unrelated signals. Rows that
        // the current firmware doesn't emit are skipped silently via
        // the `compactMap` below.
        let specs: [SpecEntry] = [
            .init(prefixes: ["EprPress"], label: "EPAP", unit: "cmH₂O", scale: 1, format: pressureFmt),
            .init(prefixes: ["Press."], label: "IPAP", unit: "cmH₂O", scale: 1, format: pressureFmt),
            .init(prefixes: ["Leak"], label: "Leak Rate", unit: "L/min", scale: 60, format: oneDecimalFmt),
            .init(prefixes: ["FlowLim"], label: "Flow Limit", unit: "index 0–1", scale: 1, format: twoDecimalFmt),
            // Tidal volume is stored in litres; multiply on the way
            // into the table so the displayed units stay millilitres
            // — matches the daily-stat card and clinical convention.
            .init(prefixes: ["TidVol"], label: "Tidal Volume", unit: "mL", scale: 1000, format: intFmt),
            .init(prefixes: ["Snore"], label: "Snore", unit: "index 0–5", scale: 1, format: oneDecimalFmt),
            .init(prefixes: ["MinVent"], label: "Minute Ventilation", unit: "L/min", scale: 1, format: twoDecimalFmt),
            .init(prefixes: ["RespRate"], label: "Respiratory Rate", unit: "bpm", scale: 1, format: oneDecimalFmt),
            .init(prefixes: ["Ti."], label: "Inspiration Time", unit: "seconds", scale: 1, format: twoDecimalFmt),
            .init(prefixes: ["Te."], label: "Expiration Time", unit: "seconds", scale: 1, format: twoDecimalFmt),
            .init(prefixes: ["I:E"], label: "I:E Ratio", unit: "ratio", scale: 1, format: twoDecimalFmt),
            .init(prefixes: ["RespEvent", "RespEvt"], label: "Respiratory Event", unit: "events", scale: 1, format: twoDecimalFmt),
        ]

        return specs.compactMap { spec -> SignalSummaryRow? in
            // First candidate prefix that actually has captured
            // samples wins. Firmware-specific naming (`RespEvent`
            // vs `RespEvt`, …) is handled at this layer so the
            // downstream percentile logic stays single-source.
            guard let matched = spec.prefixes.first(where: { key in
                !(rawByPrefix[key] ?? []).isEmpty
            }), let raw = rawByPrefix[matched] else {
                return nil
            }
            let matchedPrefix = matched
            // Apply on-therapy filter when we have one and the
            // sample arrays line up. Some signals (Tidal Volume
            // for example) sample at the same rate as MaskPress
            // so index alignment is safe.
            var filtered: [Double] = []
            filtered.reserveCapacity(raw.count)
            if useMaskFilter, raw.count == onTherapyMask.count {
                for (i, v) in raw.enumerated() where onTherapyMask[i] {
                    filtered.append(v * spec.scale)
                }
            } else {
                filtered = spec.scale == 1 ? raw : raw.map { $0 * spec.scale }
            }
            guard !filtered.isEmpty else { return nil }
            filtered.sort()
            let minV = filtered.first ?? 0
            let median = percentileValue(filtered, 50)
            let p95 = percentileValue(filtered, 95)
            let p99_5 = percentileValue(filtered, 99.5)
            return SignalSummaryRow(
                id: matchedPrefix,
                label: spec.label,
                unit: spec.unit,
                displayMin: spec.format(minV),
                displayMedian: spec.format(median),
                displayP95: spec.format(p95),
                displayP99_5: spec.format(p99_5)
            )
        }
    }

    /// Linear-interpolated percentile over a pre-sorted array.
    /// Mirrors the helper in `DailyStatistics` so the summary
    /// table's numbers line up with the daily-stat card values.
    private static func percentileValue(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = (p / 100) * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        let frac = rank - Double(low)
        return sorted[low] * (1 - frac) + sorted[high] * frac
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
    /// Target inspiratory pressure (IPAP) per breath — the upper
    /// envelope of the pressure chart. From the PLD "Press" signal.
    var ipap: [TimePoint] = []
    /// Target expiratory pressure (EPAP) per breath — the lower
    /// envelope of the pressure chart. From the PLD "EprPress" signal
    /// (empty on CPAP machines without EPR).
    var epap: [TimePoint] = []
    /// Raw (un-downsampled) samples per signal label, used by the
    /// per-night signal summary table to compute clinically
    /// accurate percentiles. Keyed by the signal's PLD prefix.
    var rawSamples: [String: [Double]] = [:]
}

private func decodePLD(
    _ pld: EDFFile,
    startOffset: TimeInterval
) -> PLDDecoded {
    var out = PLDDecoded()

    // One-time dump of the PLD signal labels we see. Cheap (a few
    // hundred bytes) and logged at debug level, but gives ground
    // truth when a firmware uses a different name for breath-timing
    // or respiratory-event signals than we expected.
    let labelList = pld.signals.map(\.label).joined(separator: ", ")
    bundleLog.debug("PLD signals: \(labelList, privacy: .public)")

    func points(
        prefix: String,
        scale: Double = 1,
        targetPoints: Int = 400,
        captureRaw: Bool = true
    ) -> [TimePoint] {
        guard let idx = pld.signals.firstIndex(where: { $0.label.hasPrefix(prefix) }),
              let samples = try? pld.physicalSamples(ofSignal: idx) else {
            return []
        }
        let signal = pld.signals[idx]
        let rate = Double(signal.samplesPerRecord) / pld.header.recordDuration
        guard rate > 0 else { return [] }
        let scaled = scale == 1 ? samples : samples.map { $0 * scale }
        // Stash the *raw* (un-scaled) samples for the summary
        // table — the spec there owns the unit conversion, so
        // we'd double-scale Leak (×60) and Tidal Volume (×1000)
        // if we cached the already-scaled values.
        if captureRaw {
            out.rawSamples[prefix, default: []].append(contentsOf: samples)
        }
        return DownsampledSignal.points(
            samples: scaled,
            sampleRate: rate,
            startOffset: startOffset,
            targetPoints: targetPoints
        )
    }

    // Mask-pressure samples gate the on-therapy filter for every
    // other signal — we capture them even though there's no
    // chart for the raw mask-pressure track.
    if let maskIdx = pld.signals.firstIndex(where: { $0.label.hasPrefix("MaskPress") }),
       let mp = try? pld.physicalSamples(ofSignal: maskIdx) {
        out.rawSamples["MaskPress", default: []].append(contentsOf: mp)
    }

    // Leak is stored in L/s; every viewer shows L/min so we scale on decode.
    out.leak = points(prefix: "Leak", scale: 60)
    out.respirationRate = points(prefix: "RespRate")
    // Exposed in mL to match the daily stats card and clinical convention.
    // Tidal volume is the signal users squint at for per-breath variation,
    // so it gets a finer bucket (~2000 pts ≈ one point per ~15 seconds
    // over an 8-hour session) than the other PLD tracks where 400 is
    // plenty for the amplitude envelopes they carry.
    out.tidalVolume = points(prefix: "TidVol", scale: 1000, targetPoints: 2000)
    out.minuteVentilation = points(prefix: "MinVent")
    out.snore = points(prefix: "Snore")
    out.flowLimitation = points(prefix: "FlowLim")
    // Pressure setpoints — note the prefix "Press." to avoid matching
    // "EprPress" and "MaskPress".
    out.ipap = points(prefix: "Press.")
    out.epap = points(prefix: "EprPress")

    // Detailed-Statistics-only signals. We don't chart these, but the
    // percentile table exposes them when the firmware emits them.
    // `targetPoints: 1` skips the downsample cost — the returned
    // points are discarded and only `rawSamples[prefix]` is used.
    //
    // Trailing dot on `Ti.` / `Te.` stops the prefix from matching
    // `TidVol.*` / `Test.*` / etc. (AirSense 10 ships `Ti.2s` and
    // `Te.2s`, so the dot is also what the firmware actually uses.)
    // `RespEvt` / `RespEvent` cover the two spellings ResMed uses
    // for the respiratory-event indicator across firmware lines.
    _ = points(prefix: "Ti.", targetPoints: 1)
    _ = points(prefix: "Te.", targetPoints: 1)
    _ = points(prefix: "RespEvent", targetPoints: 1)
    _ = points(prefix: "RespEvt", targetPoints: 1)
    _ = points(prefix: "I:E", targetPoints: 1)
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
    /// Mid-density flow samples used at 30m / 1h zooms.
    let flowMid: [TimePoint]
    /// High-resolution min-max flow samples used at tight zooms.
    let flowDetail: [TimePoint]
    let pressure: [TimePoint]
    /// 0.5 Hz signals from the paired PLD file. All empty when no PLD exists.
    let leak: [TimePoint]            // L/min (converted from L/s on decode)
    let respirationRate: [TimePoint] // bpm
    let tidalVolume: [TimePoint]     // mL
    let minuteVentilation: [TimePoint] // L/min
    let snore: [TimePoint]           // 0–5 scale
    let flowLimitation: [TimePoint]  // 0–1 scale
    let ipap: [TimePoint]            // cmH₂O — target inspiratory
    let epap: [TimePoint]            // cmH₂O — target expiratory
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
    /// Which chart the cursor is currently over. Drives the per-chart
    /// hover readout popup.
    @State private var activeHoverChart: String?

    private var visibleDomainLength: TimeInterval {
        zoomWindow > 0 ? min(zoomWindow, max(bundle.totalDuration, 1)) : max(bundle.totalDuration, 1)
    }

    private var isZoomed: Bool {
        zoomWindow > 0 && zoomWindow < bundle.totalDuration
    }

    /// Lo/hi bounds of the slice to feed each chart, with a generous
    /// margin so small scroll nudges don't trigger re-slicing.
    private var visibleBounds: (lo: TimeInterval, hi: TimeInterval)? {
        guard isZoomed else { return nil }
        let margin = visibleDomainLength
        return (max(0, scrollPosition - margin),
                scrollPosition + visibleDomainLength + margin)
    }

    /// Slice a flat array to the visible window (plus margin). Returns
    /// the full array at fit zoom, where there's no point slicing.
    private func sliced(_ points: [FlatPoint]) -> [FlatPoint] {
        guard let b = visibleBounds, !points.isEmpty else { return points }
        let start = points.lowerBound(where: { $0.offset >= b.lo })
        let end = points.lowerBound(where: { $0.offset > b.hi })
        guard start < end else { return [] }
        return Array(points[start..<end])
    }

    /// Events filtered to the visible window (plus margin). Events don't
    /// need the whole night's overlay when zoomed in to 30 s.
    private var visibleEvents: [TimedEvent] {
        guard let b = visibleBounds else { return bundle.events }
        return bundle.events.filter {
            $0.offset + $0.duration >= b.lo && $0.offset <= b.hi
        }
    }

    /// Flow samples for the current zoom state. At "fit" we use the cheap
    /// 1,500-point overview. When zoomed we slice the 50k-point detail
    /// array to just the visible window so Chart's `ForEach` is fed with
    /// at most a few thousand marks.
    private var visibleFlowPoints: [FlatPoint] {
        guard isZoomed else { return bundle.flatFlow }
        // Detail tier for ≤ 10m, mid tier above that (30m / 1h) so
        // wider zooms don't end up with tens of thousands of marks.
        if visibleDomainLength <= 600 + 1 {
            return sliced(bundle.flatFlowDetail)
        }
        return sliced(bundle.flatFlowMid)
    }

    /// Matching tier for the hover readout chip, so the sampled
    /// value shown there comes from the same array the chart drew.
    private var hoverFlowSource: [FlatPoint] {
        guard isZoomed else { return bundle.flatFlow }
        if visibleDomainLength <= 600 + 1 {
            return bundle.flatFlowDetail
        }
        return bundle.flatFlowMid
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
            // Auto-dismiss the readout after a few seconds so it
            // doesn't linger once the user has glanced at it. The
            // task re-starts every time `hoverOffset` changes
            // (different click position, or cleared by a second tap),
            // and cancels when the view goes away.
            .task(id: hoverOffset) {
                guard hoverOffset != nil else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 s
                guard !Task.isCancelled else { return }
                hoverOffset = nil
                activeHoverChart = nil
            }
    }

    /// Inline tip below the timeline strip explaining the two
    /// gestures it carries: scrub the shaded viewport to focus
    /// the data charts, or tap a chart to drop a probe with
    /// numeric readouts. Subtle so it doesn't compete with the
    /// data, but visible enough to teach a new user without a
    /// help screen.
    @ViewBuilder
    private var timelineHelpText: some View {
        Label {
            Text("Drag the timeline to focus the charts below. Tap a chart to inspect values at a moment.")
        } icon: {
            Image(systemName: "hand.tap")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
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
            if bundle.isEmpty {
                ContentUnavailableView(
                    "No session data",
                    systemImage: "moon.zzz",
                    description: Text("This day has no complete sessions.")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                zoomControls
                SessionTimelineView(
                    bundle: bundle,
                    onJumpToTime: { time in jumpTo(time: time) },
                    onDragToTime: { time in panViewport(center: time) },
                    viewportStart: scrollPosition,
                    viewportLength: isZoomed ? visibleDomainLength : 0
                )
                timelineHelpText

                chartStack
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
                    value: hoverValue(hoverFlowSource),
                    unit: flowUnit,
                    format: "%.1f",
                    color: .primary
                )
                if !bundle.flatEPAP.isEmpty {
                    readoutChip(
                        "EPAP",
                        value: hoverValue(bundle.flatEPAP),
                        unit: pressureUnit,
                        format: "%.1f",
                        color: .chartBlue
                    )
                }
                if !bundle.flatIPAP.isEmpty {
                    readoutChip(
                        "IPAP",
                        value: hoverValue(bundle.flatIPAP),
                        unit: pressureUnit,
                        format: "%.1f",
                        color: .chartOrange
                    )
                }
                if bundle.flatIPAP.isEmpty {
                    readoutChip(
                        "Pressure",
                        value: hoverValue(bundle.flatPressure),
                        unit: pressureUnit,
                        format: "%.1f",
                        color: .purple
                    )
                }
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
                        unit: "mL",
                        format: "%.0f",
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
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .allowsHitTesting(false)
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

    static let chartHeight: CGFloat = 180

    /// Preset zoom windows in seconds. `0` means "fit the whole night".
    private static let zoomPresets: [(label: String, seconds: TimeInterval)] = [
        ("All", 0),
        ("1h", 3600),
        ("30m", 1800),
        ("10m", 600),
        ("2m", 120),
        ("30s", 30)
    ]

    @ViewBuilder
    private var zoomControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Picker on top so the user reaches for the zoom
            // control first, then the Timeline heading reads as
            // a label for the chart that follows below.
            Picker("Zoom", selection: zoomSelection) {
                ForEach(Self.zoomPresets, id: \.label) { preset in
                    Text(preset.label).tag(preset.seconds)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ChartSubviewTitle(title: "Timeline", subtitle: zoomRangeLabel)
        }
    }

    /// Picker binding that maps the `zoomWindow` state to whichever
    /// preset it currently matches (or the closest preset if the
    /// user pinched to an intermediate value).
    private var zoomSelection: Binding<TimeInterval> {
        Binding(
            get: {
                Self.zoomPresets
                    .min(by: {
                        Swift.abs($0.seconds - zoomWindow) <
                        Swift.abs($1.seconds - zoomWindow)
                    })?
                    .seconds ?? 0
            },
            set: { newValue in applyZoom(seconds: newValue) }
        )
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

    /// Pan the viewport so the given time sits at the centre of
    /// the currently-zoomed window. Called on every drag frame from
    /// `SessionTimelineView` — deliberately *not* wrapped in
    /// `withAnimation` so the shaded band tracks the pointer at
    /// 60 fps without queueing overlapping easings.
    private func panViewport(center time: TimeInterval) {
        let window: TimeInterval = zoomWindow > 0
            ? zoomWindow
            : min(600, max(bundle.totalDuration, 1))
        let clamped = min(window, max(bundle.totalDuration, 1))
        var newStart = time - clamped / 2
        newStart = max(0, min(newStart, max(0, bundle.totalDuration - clamped)))
        // If the user scrubs the timeline from fit-zoom we snap
        // into the default 10-minute window on the first drag and
        // then follow the finger — matches how tap behaves.
        if zoomWindow == 0 {
            zoomWindow = clamped
        }
        scrollPosition = newStart
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
        // At "All" (un-zoomed) show the full session span — not the
        // scroll-window anchored bounds, which collapse to dayStart.
        let startOffset = isZoomed ? scrollPosition : 0
        let endOffset = isZoomed
            ? scrollPosition + visibleDomainLength
            : bundle.totalDuration
        let start = bundle.dayStart.addingTimeInterval(startOffset)
        let end = bundle.dayStart.addingTimeInterval(endOffset)
        let startStr = start.formatted(date: .omitted, time: .shortened)
        let endStr = end.formatted(date: .omitted, time: .shortened)
        return "\(startStr) – \(endStr)"
    }

    /// Stack of signal charts. Each chart is its own `EquatableView` so
    /// SwiftUI short-circuits re-rendering when only hover / scroll has
    /// changed but the chart's own data hasn't.
    @ViewBuilder
    private var chartStack: some View {
        // Capture the day-start by value so the closure doesn't need to
        // capture `self` and can stay `@Sendable`.
        let dayStart = bundle.dayStart
        let axes = SharedAxisConfig(
            totalDuration: bundle.totalDuration,
            visibleDomainLength: visibleDomainLength,
            isZoomed: isZoomed,
            dayStart: dayStart,
            scrollBinding: $scrollPosition,
            hoverBinding: $hoverOffset,
            clockLabel: { offset in
                dayStart.addingTimeInterval(offset)
                    .formatted(date: .omitted, time: .shortened)
            }
        )

        withHoverOverlay(tag: "Breathing") {
            EquatableCanvasSignalLineChart(
                title: "Breathing",
                unit: flowUnit,
                points: visibleFlowPoints,
                events: visibleEvents,
                color: .primary,
                zeroReference: true,
                stepped: false,
                thresholdY: nil,
                hoverOffset: hoverOffset,
                axes: axes
            )
        }
        withHoverOverlay(tag: "Pressure") {
            // Prefer the per-breath IPAP / EPAP target traces from the
            // PLD files — they give two clean step-lines bracketing
            // what the machine is delivering. Fall back to the raw BRP
            // mask pressure when no PLD data is available.
            let ipap = sliced(bundle.flatIPAP)
            let epap = sliced(bundle.flatEPAP)
            let mask = sliced(bundle.flatPressure)

            let domain: ClosedRange<Double>? = {
                let values = (ipap + epap + mask).map(\.value)
                guard let lo = values.min(), let hi = values.max() else { return nil }
                return (lo - 1)...(hi + 1)
            }()

            EquatableCanvasPressureChart(
                title: "Pressure",
                unit: pressureUnit,
                ipap: ipap,
                epap: epap,
                fallback: ipap.isEmpty ? mask : [],
                yDomain: domain,
                hoverOffset: hoverOffset,
                axes: axes
            )
        }
        if hasLeak {
            withHoverOverlay(tag: "Leak") {
                EquatableCanvasSignalLineChart(
                    title: "Leak",
                    unit: "L/min",
                    points: sliced(bundle.flatLeak),
                    events: [],
                    color: .yellow,
                    zeroReference: false,
                    stepped: false,
                    thresholdY: 24,
                    hoverOffset: hoverOffset,
                    axes: axes
                )
            }
        }
        if hasFlowLim {
            withHoverOverlay(tag: "FlowLim") {
                EquatableCanvasSignalAreaChart(
                    title: "Flow Limitation",
                    subtitle: "index (0–1)",
                    points: sliced(bundle.flatFlowLimitation),
                    color: .pink,
                    yDomain: 0...1,
                    hoverOffset: hoverOffset,
                    axes: axes
                )
            }
        }
        if hasTidalVolume {
            withHoverOverlay(tag: "TidalVol") {
                EquatableCanvasSignalLineChart(
                    title: "Tidal Volume",
                    unit: "mL",
                    points: sliced(bundle.flatTidalVolume),
                    events: [],
                    color: .indigo,
                    zeroReference: false,
                    stepped: false,
                    thresholdY: nil,
                    hoverOffset: hoverOffset,
                    axes: axes
                )
            }
        }
        if hasSnore {
            withHoverOverlay(tag: "Snore") {
                EquatableCanvasSignalAreaChart(
                    title: "Snore",
                    subtitle: "index (0–5)",
                    points: sliced(bundle.flatSnore),
                    color: .green,
                    yDomain: 0...5,
                    hoverOffset: hoverOffset,
                    axes: axes
                )
            }
        }
    }

    /// Wrap a chart with hover tracking + a top-trailing popup of the
    /// readout that only appears when the cursor is over *this* chart.
    /// Wraps a chart so the per-chart readout popup surfaces only
    /// while `hoverOffset` is non-nil — which, under the tap-to-show
    /// model, means the user has actively clicked a chart to drop a
    /// probe. `tag` scopes which chart displays the popup so we show
    /// it over the one that was just tapped.
    @ViewBuilder
    private func withHoverOverlay<C: View>(
        tag: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        content()
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        // Record which chart received the tap so the
                        // readout appears over it. The chart itself
                        // still owns hover-offset positioning (via
                        // its own tap/selection handler) since the
                        // x coordinate lives there.
                        activeHoverChart = tag
                    }
            )
            .overlay(alignment: .topTrailing) {
                if activeHoverChart == tag && hoverOffset != nil {
                    hoverReadout
                        .padding(.trailing, 12)
                        .padding(.top, 4)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: activeHoverChart == tag && hoverOffset != nil)
    }

    /// Y-axis label column width (32) + a small gap so chart headers line
    /// up with where the plot area actually starts.
    static let plotAreaLeadingInset: CGFloat = 40

    private func clockLabel(for offset: TimeInterval) -> String {
        let date = bundle.dayStart.addingTimeInterval(offset)
        return date.formatted(date: .omitted, time: .shortened)
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

/// Axis / scroll / hover configuration passed down to each chart subview.
/// Grouping it into one struct lets the subviews conform to `Equatable`
/// cleanly — two `SharedAxisConfig` values are equal when the visible
/// window and zoom state match, so SwiftUI can skip re-rendering charts
/// whose data hasn't changed during a pure hover update.
struct SharedAxisConfig: Equatable, Sendable {
    let totalDuration: TimeInterval
    let visibleDomainLength: TimeInterval
    let isZoomed: Bool
    /// Wall-clock start of the first session. Lets the tick generator
    /// align ticks to round times (e.g., 12:00 AM, 12:30 AM) instead
    /// of offsets from the session origin.
    let dayStart: Date
    let scrollBinding: Binding<TimeInterval>
    let hoverBinding: Binding<TimeInterval?>
    let clockLabel: @Sendable (TimeInterval) -> String

    nonisolated static func == (lhs: SharedAxisConfig, rhs: SharedAxisConfig) -> Bool {
        lhs.totalDuration == rhs.totalDuration
            && lhs.visibleDomainLength == rhs.visibleDomainLength
            && lhs.isZoomed == rhs.isZoomed
            && lhs.dayStart == rhs.dayStart
    }
}


struct ChartSubviewTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.headline)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum ChartSubviewHelpers {
    static func eventColor(_ text: String) -> Color {
        let lower = text.lowercased()
        if lower.contains("obstructive") { return .eventObstructive }
        if lower.contains("central") { return .eventCentral }
        if lower.contains("hypopnea") { return .eventHypopnea }
        return .gray
    }
}


