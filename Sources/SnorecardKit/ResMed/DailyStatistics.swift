import Foundation

/// One day's aggregate statistics decoded from a `STR.edf` record.
///
/// Only the fields a CPAP user typically cares about are surfaced here.
/// `-1` sentinel values from the device are normalised to `nil`.
public struct DailyStatistics: Sendable, Equatable, Codable {
    public let date: Date
    public let usageMinutes: Double
    public let maskEvents: Int
    public let ahi: Double
    public let hypopneaIndex: Double
    public let apneaIndex: Double
    public let obstructiveApneaIndex: Double
    public let centralApneaIndex: Double
    public let unspecifiedApneaIndex: Double
    public let pressureMedian: Double?
    public internal(set) var pressure95: Double?
    public let pressureMax: Double?
    public internal(set) var ipap95: Double?
    public internal(set) var epap95: Double?
    public let leak95LPerMin: Double?
    public let leakMaxLPerMin: Double?
    /// Total seconds spent in apnea/hypopnea events — sum of every EVE
    /// annotation's duration. `nil` when we couldn't read any EVE files.
    public internal(set) var timeInApneaSeconds: Double? = nil
    /// Total seconds where mask leak exceeded the 24 L/min large-leak
    /// threshold, summed across all PLD samples on therapy.
    public internal(set) var largeLeakSeconds: Double? = nil
    public internal(set) var glasgowIndex: Double? = nil
    /// 9-sub-index breakdown that drives `glasgowIndex`. `nil` on
    /// nights without BRP coverage (e.g. AirSense 11 STR-only days)
    /// or when the cached payload predates this field. The 9 values
    /// sum to `glasgowIndex`.
    public internal(set) var glasgowBreakdown: GlasgowIndex.Breakdown? = nil
    public internal(set) var flowLimit95: Double?
    /// 95th-percentile snore index from the PLD `Snore` signal,
    /// on-therapy samples only. ResMed reports snore on a 0–5
    /// scale. `nil` when no PLD was available or the signal was
    /// absent for the night (older firmware, STR-only records).
    public internal(set) var snore95: Double? = nil
    /// On-therapy seconds with snore index in the 1.5–3.0 band —
    /// ResScan's "moderately loud snoring" icon range. Derived
    /// from the same gated PLD stream as `snore95`. `nil` when
    /// no PLD was available. Lets the UI describe the night as
    /// a loudness class ("Mild" / "Moderate" / "Loud") instead
    /// of a bare machine number.
    public internal(set) var snoreModerateSeconds: Double? = nil
    /// On-therapy seconds with snore index ≥ 3.0 — ResScan's
    /// "loud snoring" icon range (and above, since >3 runs off
    /// the top of ResScan's scale). Companion to
    /// `snoreModerateSeconds`.
    public internal(set) var snoreLoudSeconds: Double? = nil
    /// Snapshot of therapy / comfort / humidifier / accessory
    /// settings active for this day, decoded from STR.edf's `S.*`
    /// signals. Nil when STR.edf has no record for the day (e.g.
    /// AirSense 11 where STR.edf is empty).
    public internal(set) var settings: DeviceSettings? = nil
    public let minuteVentilation50: Double?
    public let respirationRate50: Double?
    public let tidalVolume50: Double?
    public let modeCode: Int?
    /// Parsed `#PNA` product identifier from `Identification.tgt` —
    /// e.g. "AirSense 10 CPAP", "AirCurve 10 VAuto". Threaded in from
    /// `ResMedSDCard.identification` so `modeName` can resolve a
    /// device-specific label instead of guessing from the numeric code.
    public let productName: String?

    public var usageHours: Double { usageMinutes / 60 }
    public var hasUsage: Bool { usageMinutes > 0 }

    /// Human label for the therapy mode, matching the casing the ResMed
    /// device itself shows on its screen (e.g. `VPAPauto`, not `VAuto`).
    ///
    /// We first check the product name for device families that only
    /// support a single mode (AirCurve VAuto is always VPAPauto, AirCurve
    /// ASV is always ASV/ASVauto, etc.) and only fall back to the numeric
    /// mode code for everything else.
    public var modeName: String {
        if let name = productName?.lowercased() {
            // AirCurve device families — product name uniquely determines
            // the mode (or narrows it to a small set).
            if name.contains("vauto") { return "VPAPauto" }
            if name.contains("aircurve") && name.contains("asv") {
                return modeCode == 13 ? "ASVauto" : "ASV"
            }
            if name.contains("aircurve") && (name.contains("st-a") || name.contains("sta")) {
                return modeCode == 11 ? "iVAPS" : "VPAP ST"
            }
            if name.contains("aircurve") && name.hasSuffix(" st") {
                return "VPAP ST"
            }
            if name.contains("aircurve") && name.hasSuffix(" s") {
                return "VPAP S"
            }
        }

        switch modeCode {
        case 1: return "CPAP"
        case 2: return "APAP"
        case 3, 6: return "AutoSet"
        case 7: return "AutoSet for Her"
        case 8: return "VPAPauto"
        case 9: return "VPAP S"
        case 10: return "VPAP ST"
        case 11: return "iVAPS"
        case 12: return "ASV"
        case 13: return "ASVauto"
        default: return modeCode.map { "Mode \($0)" } ?? "—"
        }
    }
}

extension DailyStatistics {
    /// Fallback daily summary computed from the raw DATALOG files for days that
    /// STR.edf doesn't cover (for example, older nights the device rolled out
    /// of the summary file). Usage and AHI come from BRP headers and EVE
    /// annotations; percentile-based metrics come from the PLD signals,
    /// filtered to on-therapy instants (mask pressure above 1 cmH₂O).
    public static func compute(
        for day: ResMedDay,
        productName: String? = nil
    ) -> DailyStatistics? {
        let brp = day.files(of: .breath)
        guard !brp.isEmpty else { return nil }

        var usageSeconds: Double = 0
        for file in brp {
            guard let edf = try? EDFFile(contentsOf: file.url),
                  edf.header.recordCount > 0 else { continue }
            usageSeconds += Double(edf.header.recordCount) * edf.header.recordDuration
        }
        let usageMinutes = usageSeconds / 60
        let usageHours = usageMinutes / 60

        var obstructive = 0
        var central = 0
        var unspecified = 0
        var hypopnea = 0

        for file in day.files(of: .events) {
            guard let edf = try? EDFFile(contentsOf: file.url),
                  let annotations = try? edf.annotations() else { continue }
            for annotation in annotations {
                let text = annotation.text.lowercased()
                if text.contains("obstructive") {
                    obstructive += 1
                } else if text.contains("central") {
                    central += 1
                } else if text.contains("hypopnea") {
                    hypopnea += 1
                } else if text.contains("apnea") {
                    unspecified += 1
                }
            }
        }

        let apneas = obstructive + central + unspecified
        func rate(_ count: Int) -> Double {
            usageHours > 0 ? Double(count) / usageHours : 0
        }

        // --- Percentile metrics from PLD, filtered to on-therapy instants. ---
        var pressures: [Double] = []
        var ipaps: [Double] = []   // Target inspiratory pressure (base Press.2s).
        var epaps: [Double] = []   // Target expiratory pressure (EprPress.2s).
        var leaks: [Double] = []
        var flowLims: [Double] = []
        var minVents: [Double] = []
        var respRates: [Double] = []
        var tidVols: [Double] = []
        var snores: [Double] = []

        for file in day.files(of: .physiological) {
            guard let edf = try? EDFFile(contentsOf: file.url),
                  edf.header.recordCount > 0 else { continue }

            func decode(_ prefix: String) -> [Double] {
                guard let idx = edf.signals.firstIndex(where: { $0.label.hasPrefix(prefix) }),
                      let decoded = try? edf.physicalSamples(ofSignal: idx) else {
                    return []
                }
                return decoded
            }

            let pressure = decode("MaskPress")
            guard !pressure.isEmpty else { continue }
            let ipap = decode("Press.")
            let epap = decode("EprPress")
            let leak = decode("Leak")
            let fl = decode("FlowLim")
            let mv = decode("MinVent")
            let rr = decode("RespRate")
            let tv = decode("TidVol")
            let snore = decode("Snore")

            for i in pressure.indices where pressure[i] > 1.0 {
                pressures.append(pressure[i])
                if i < ipap.count { ipaps.append(ipap[i]) }
                if i < epap.count { epaps.append(epap[i]) }
                if i < leak.count { leaks.append(leak[i]) }
                if i < fl.count { flowLims.append(fl[i]) }
                if i < mv.count { minVents.append(mv[i]) }
                if i < rr.count { respRates.append(rr[i]) }
                if i < tv.count { tidVols.append(tv[i]) }
                if i < snore.count { snores.append(snore[i]) }
            }
        }

        let pressureMedian = percentile(pressures, 50)
        let pressure95 = percentile(pressures, 95)
        let ipap95 = percentile(ipaps, 95)
        let epap95 = percentile(epaps, 95)
        let leak95 = percentile(leaks, 95).map { $0 * 60 } // L/s → L/min
        let leakMax = leaks.max().map { $0 * 60 }

        var stats = DailyStatistics(
            date: day.date,
            usageMinutes: usageMinutes,
            maskEvents: brp.count,
            ahi: rate(apneas + hypopnea),
            hypopneaIndex: rate(hypopnea),
            apneaIndex: rate(apneas),
            obstructiveApneaIndex: rate(obstructive),
            centralApneaIndex: rate(central),
            unspecifiedApneaIndex: rate(unspecified),
            pressureMedian: pressureMedian,
            pressure95: pressure95,
            pressureMax: pressures.max(),
            ipap95: ipap95,
            epap95: epap95,
            leak95LPerMin: leak95,
            leakMaxLPerMin: leakMax,
            flowLimit95: percentile(flowLims, 95),
            minuteVentilation50: percentile(minVents, 50),
            respirationRate50: percentile(respRates, 50),
            tidalVolume50: percentile(tidVols, 50),
            modeCode: nil,
            productName: productName
        )
        stats.snore95 = percentile(snores, 95)
        let snoreBands = snoreBandSeconds(samples: snores, usageMinutes: usageMinutes)
        stats.snoreModerateSeconds = snoreBands.moderate
        stats.snoreLoudSeconds = snoreBands.loud
        return stats
    }

    /// Aggregate metrics computed from a day's raw EVE and PLD files.
    /// Matches what OSCAR / SleepHQ show by computing percentiles
    /// directly from PLD samples (STR.edf pre-aggregated values like
    /// `TgtEPAP.95` are the *target* pressure, not the measured one).
    public struct SupplementaryMetrics {
        public var timeInApnea: Double?
        public var largeLeak: Double?
        public var flowLimit95: Double?
        /// PLD-measured 95th percentile EPAP, on-therapy samples only.
        public var maskEpap95: Double?
        /// PLD-measured 95th percentile IPAP, on-therapy samples only.
        public var maskIpap95: Double?
        /// PLD-measured 95th percentile mask pressure, on-therapy only.
        public var maskPressure95: Double?
    }

    /// Re-read a day's EVE and PLD files to compute metrics that STR.edf
    /// doesn't pre-aggregate or that OSCAR computes differently (like
    /// the measured pressure percentiles vs STR's target values).
    public static func supplementaryMetrics(
        for day: ResMedDay
    ) -> SupplementaryMetrics {
        var timeInApnea: Double = 0
        var sawAnyEVE = false
        for file in day.files(of: .events) {
            guard let edf = try? EDFFile(contentsOf: file.url),
                  let annotations = try? edf.annotations() else { continue }
            sawAnyEVE = true
            for annotation in annotations {
                let text = annotation.text.lowercased()
                guard text.contains("apnea") || text.contains("hypopnea") else { continue }
                timeInApnea += annotation.duration ?? 0
            }
        }

        var largeLeakSeconds: Double = 0
        var sawAnyPLD = false
        var flowLims: [Double] = []
        var maskPressures: [Double] = []
        var ipaps: [Double] = []
        var epaps: [Double] = []
        // Leak is stored in L/s, so the 24 L/min threshold is 24/60 = 0.4 L/s.
        let threshold: Double = 24.0 / 60.0
        for file in day.files(of: .physiological) {
            guard let edf = try? EDFFile(contentsOf: file.url),
                  edf.header.recordCount > 0 else { continue }

            // Leak large-leak accumulation.
            if let idx = edf.signals.firstIndex(where: { $0.label.hasPrefix("Leak") }),
               let samples = try? edf.physicalSamples(ofSignal: idx) {
                let signal = edf.signals[idx]
                let rate = Double(signal.samplesPerRecord) / edf.header.recordDuration
                if rate > 0 {
                    sawAnyPLD = true
                    let sampleInterval = 1.0 / rate
                    let aboveCount = samples.reduce(into: 0) { count, sample in
                        if sample > threshold { count += 1 }
                    }
                    largeLeakSeconds += Double(aboveCount) * sampleInterval
                }
            }

            // Pressure / flow-limit samples — filtered to on-therapy
            // (mask pressure > 1 cmH2O).
            let mp: [Double] = edf.signals.firstIndex(where: { $0.label.hasPrefix("MaskPress") })
                .flatMap { try? edf.physicalSamples(ofSignal: $0) } ?? []
            let ip: [Double] = edf.signals.firstIndex(where: { $0.label.hasPrefix("Press.") })
                .flatMap { try? edf.physicalSamples(ofSignal: $0) } ?? []
            let ep: [Double] = edf.signals.firstIndex(where: { $0.label.hasPrefix("EprPress") })
                .flatMap { try? edf.physicalSamples(ofSignal: $0) } ?? []
            let fl: [Double] = edf.signals.firstIndex(where: { $0.label.hasPrefix("FlowLim") })
                .flatMap { try? edf.physicalSamples(ofSignal: $0) } ?? []

            for i in mp.indices where mp[i] > 1.0 {
                maskPressures.append(mp[i])
                if i < ip.count { ipaps.append(ip[i]) }
                if i < ep.count { epaps.append(ep[i]) }
                if i < fl.count { flowLims.append(fl[i]) }
            }
        }

        return SupplementaryMetrics(
            timeInApnea: sawAnyEVE ? timeInApnea : nil,
            largeLeak: sawAnyPLD ? largeLeakSeconds : nil,
            flowLimit95: percentile(flowLims, 95),
            maskEpap95: percentile(epaps, 95),
            maskIpap95: percentile(ipaps, 95),
            maskPressure95: percentile(maskPressures, 95)
        )
    }

    /// Single-pass aggregate for a day's raw files — decodes each BRP /
    /// EVE / PLD file exactly once and builds a fully-populated
    /// `DailyStatistics`. Replaces the combination of `compute` +
    /// `supplementaryMetrics` + `GlasgowIndex.computeDay` that the
    /// importer previously ran, cutting ~50 % of I/O per day.
    ///
    /// `excluding` is a set of `sessionKey` values (the `YYYYMMDD_HHMMSS`
    /// filename prefix shared by a session's BRP / EVE / PLD trio).
    /// Files whose key is in the set are skipped on every pass, so the
    /// resulting AHI / usage / pressure stats reflect only the kept
    /// sessions. An empty set is the original behaviour.
    ///
    /// Sessions whose recorded duration is below `minSessionSeconds`
    /// (default: 120 s) are auto-excluded on top of the explicit set.
    /// These are virtually always mask tests / fittings / brief
    /// daytime checks rather than therapy and would otherwise drag
    /// the day's percentiles toward whatever mid-fitting pressure was
    /// momentarily applied.
    public static func aggregate(
        for day: ResMedDay,
        productName: String? = nil,
        excluding: Set<String> = [],
        minSessionSeconds: Double = 120
    ) -> DailyStatistics? {
        // BRP filenames carry the session's canonical `YYYYMMDD_HHMMSS`
        // timestamp, so manual exclusions match BRP files by exact
        // key. EVE / PLD siblings frequently sit a second or two off
        // their BRP, so they're paired below via "nearest BRP wins"
        // matching — same idea `WaveformBundle.load` uses to align
        // BRP with PLD.
        func isKeptBRP(_ file: ResMedDataFile) -> Bool {
            guard !excluding.isEmpty, let key = file.sessionKey else { return true }
            return !excluding.contains(key)
        }

        // Per-BRP record used to pair EVE / PLD against. The kept
        // flag bakes in both the manual exclusion set and the
        // brief-session auto-rule, so a sibling whose nearest BRP
        // is excluded for either reason gets dropped from the
        // aggregate uniformly.
        struct BRPRecord {
            let file: ResMedDataFile
            let edf: EDFFile
            let timestamp: Date
            let durationSeconds: Double
            let isKept: Bool
        }
        var brpRecords: [BRPRecord] = []
        for file in day.files(of: .breath) {
            guard let edf = try? EDFFile(contentsOf: file.url),
                  edf.header.recordCount > 0 else { continue }
            let durationSeconds = Double(edf.header.recordCount) * edf.header.recordDuration
            // Prefer the filename-parsed timestamp (matches what
            // `parseFileTimestamp` derives elsewhere) and fall back
            // to the EDF header's start date for safety.
            let ts = file.timestamp ?? edf.header.startDate
            let kept = isKeptBRP(file) && durationSeconds >= minSessionSeconds
            brpRecords.append(
                BRPRecord(
                    file: file,
                    edf: edf,
                    timestamp: ts,
                    durationSeconds: durationSeconds,
                    isKept: kept
                )
            )
        }
        guard !brpRecords.isEmpty else { return nil }

        // BRP pass: usage + Glasgow Index, kept records only.
        var usageSeconds: Double = 0
        var totalGlasgowScore: Double = 0
        var weightedBreakdown = GlasgowIndex.BreakdownAccumulator()
        var totalInspirations = 0
        var keptBRPCount = 0
        for record in brpRecords where record.isKept {
            keptBRPCount += 1
            usageSeconds += record.durationSeconds

            let edf = record.edf
            guard let flowIdx = edf.signals.firstIndex(where: { $0.label.hasPrefix("Flow") }),
                  let flowSamples = try? edf.physicalSamples(ofSignal: flowIdx)
            else { continue }
            let unit = edf.signals[flowIdx].physicalDimension
                .trimmingCharacters(in: .whitespaces).lowercased()
            let scale: Double = unit.contains("l/s") ? 60 : 1
            let flowLPerMin = scale == 1 ? flowSamples : flowSamples.map { $0 * scale }
            if let result = GlasgowIndex.compute(flowSamples: flowLPerMin) {
                let weight = Double(result.inspirationCount)
                totalGlasgowScore += result.score * weight
                weightedBreakdown.add(result.breakdown, weight: weight)
                totalInspirations += result.inspirationCount
            }
        }
        // Every BRP was below the threshold or excluded — there's
        // nothing left to aggregate for the day.
        guard usageSeconds > 0 else { return nil }

        // Build absolute time windows for the kept BRP sessions.
        // EVE annotations get filtered against these windows below
        // (per-annotation, since one EVE file can carry events from
        // multiple sessions on AirSense firmwares — observed in
        // real-world data: a folder with 3 BRPs but only 2 EVE
        // files, with each EVE spanning across session boundaries).
        let keptWindows: [(start: Date, end: Date)] = brpRecords
            .filter { $0.isKept }
            .map { record in
                let start = record.timestamp
                let end = start.addingTimeInterval(record.durationSeconds)
                return (start, end)
            }
        func isInKeptWindow(_ time: Date) -> Bool {
            keptWindows.contains { time >= $0.start && time <= $0.end }
        }

        // PLD files are written one-per-session, so per-file pairing
        // is enough. Direct sessionKey check first (catches the
        // common BRP/PLD-share-prefix case), then nearest-BRP
        // fallback for firmwares that drift the PLD timestamp a
        // second or two off the BRP. Manual exclusions only —
        // brief BRPs are filtered out of usage, but their PLD
        // samples (typically ~zero on-therapy samples anyway)
        // wouldn't move the day's percentiles meaningfully.
        func nearestBRPIsKept(_ file: ResMedDataFile) -> Bool {
            guard !excluding.isEmpty else { return true }
            if let ownKey = file.sessionKey, excluding.contains(ownKey) {
                return false
            }
            guard let ts = file.timestamp else { return true }
            guard let nearest = brpRecords.min(by: {
                abs($0.timestamp.timeIntervalSince(ts)) < abs($1.timestamp.timeIntervalSince(ts))
            }) else { return true }
            guard let nearestKey = nearest.file.sessionKey else { return true }
            return !excluding.contains(nearestKey)
        }
        let usageMinutes = usageSeconds / 60
        let usageHours = usageMinutes / 60
        let glasgowIndex: Double? = totalInspirations > 0
            ? totalGlasgowScore / Double(totalInspirations)
            : nil
        let glasgowBreakdown: GlasgowIndex.Breakdown? = totalInspirations > 0
            ? weightedBreakdown.finalize(totalWeight: Double(totalInspirations))
            : nil

        // EVE pass: apnea/hypopnea counts + total time in events.
        // Each annotation's absolute time is compared against the
        // kept session windows, not against the EVE file's own
        // timestamp — ResMed sometimes packs events from multiple
        // sessions into a single EVE file, so per-file pairing
        // would either over- or under-count.
        var obstructive = 0
        var central = 0
        var unspecified = 0
        var hypopnea = 0
        var timeInApnea: Double = 0
        var sawAnyEVE = false
        for file in day.files(of: .events) {
            guard let edf = try? EDFFile(contentsOf: file.url),
                  let annotations = try? edf.annotations() else { continue }
            sawAnyEVE = true
            let eveStart = edf.header.startDate
            for annotation in annotations {
                let absTime = eveStart.addingTimeInterval(annotation.onset)
                guard isInKeptWindow(absTime) else { continue }
                let text = annotation.text.lowercased()
                let isEvent: Bool
                if text.contains("obstructive") { obstructive += 1; isEvent = true }
                else if text.contains("central") { central += 1; isEvent = true }
                else if text.contains("hypopnea") { hypopnea += 1; isEvent = true }
                else if text.contains("apnea") { unspecified += 1; isEvent = true }
                else { isEvent = false }
                if isEvent { timeInApnea += annotation.duration ?? 0 }
            }
        }
        let apneas = obstructive + central + unspecified
        func rate(_ count: Int) -> Double {
            usageHours > 0 ? Double(count) / usageHours : 0
        }

        // PLD pass: all percentile metrics + large-leak seconds in one
        // trip through each physiological file.
        var pressures: [Double] = []
        var ipaps: [Double] = []
        var epaps: [Double] = []
        var leaks: [Double] = []
        var flowLims: [Double] = []
        var minVents: [Double] = []
        var respRates: [Double] = []
        var tidVols: [Double] = []
        var snores: [Double] = []
        var largeLeakSeconds: Double = 0
        var sawAnyPLD = false
        let leakThreshold: Double = 24.0 / 60.0 // 24 L/min in L/s

        for file in day.files(of: .physiological) where nearestBRPIsKept(file) {
            guard let edf = try? EDFFile(contentsOf: file.url),
                  edf.header.recordCount > 0 else { continue }

            func samples(_ prefix: String) -> [Double] {
                guard let idx = edf.signals.firstIndex(where: { $0.label.hasPrefix(prefix) }),
                      let decoded = try? edf.physicalSamples(ofSignal: idx)
                else { return [] }
                return decoded
            }

            let pressure = samples("MaskPress")
            guard !pressure.isEmpty else { continue }
            let ipap = samples("Press.")
            let epap = samples("EprPress")
            let leak = samples("Leak")
            let fl = samples("FlowLim")
            let mv = samples("MinVent")
            let rr = samples("RespRate")
            let tv = samples("TidVol")
            let snore = samples("Snore")

            sawAnyPLD = true

            for i in pressure.indices where pressure[i] > 1.0 {
                pressures.append(pressure[i])
                if i < ipap.count { ipaps.append(ipap[i]) }
                if i < epap.count { epaps.append(epap[i]) }
                if i < leak.count { leaks.append(leak[i]) }
                if i < fl.count { flowLims.append(fl[i]) }
                if i < mv.count { minVents.append(mv[i]) }
                if i < rr.count { respRates.append(rr[i]) }
                if i < tv.count { tidVols.append(tv[i]) }
                if i < snore.count { snores.append(snore[i]) }
            }

            // Large-leak seconds uses every sample (matches existing
            // behavior in `supplementaryMetrics`).
            if let leakIdx = edf.signals.firstIndex(where: { $0.label.hasPrefix("Leak") }) {
                let sig = edf.signals[leakIdx]
                let sampleRate = Double(sig.samplesPerRecord) / edf.header.recordDuration
                if sampleRate > 0 {
                    let interval = 1.0 / sampleRate
                    let above = leak.reduce(into: 0) { count, sample in
                        if sample > leakThreshold { count += 1 }
                    }
                    largeLeakSeconds += Double(above) * interval
                }
            }
        }

        var stats = DailyStatistics(
            date: day.date,
            usageMinutes: usageMinutes,
            maskEvents: keptBRPCount,
            ahi: rate(apneas + hypopnea),
            hypopneaIndex: rate(hypopnea),
            apneaIndex: rate(apneas),
            obstructiveApneaIndex: rate(obstructive),
            centralApneaIndex: rate(central),
            unspecifiedApneaIndex: rate(unspecified),
            pressureMedian: percentile(pressures, 50),
            pressure95: percentile(pressures, 95),
            pressureMax: pressures.max(),
            ipap95: percentile(ipaps, 95),
            epap95: percentile(epaps, 95),
            leak95LPerMin: percentile(leaks, 95).map { $0 * 60 },
            leakMaxLPerMin: leaks.max().map { $0 * 60 },
            timeInApneaSeconds: sawAnyEVE ? timeInApnea : nil,
            largeLeakSeconds: sawAnyPLD ? largeLeakSeconds : nil,
            glasgowIndex: glasgowIndex,
            flowLimit95: percentile(flowLims, 95),
            minuteVentilation50: percentile(minVents, 50),
            respirationRate50: percentile(respRates, 50),
            tidalVolume50: percentile(tidVols, 50),
            modeCode: nil,
            productName: productName
        )
        stats.snore95 = percentile(snores, 95)
        let snoreBands = snoreBandSeconds(samples: snores, usageMinutes: usageMinutes)
        stats.snoreModerateSeconds = snoreBands.moderate
        stats.snoreLoudSeconds = snoreBands.loud
        stats.glasgowBreakdown = glasgowBreakdown
        return stats
    }

    /// Convert the gated on-therapy snore samples into seconds in
    /// the moderate (1.5–3.0) and loud (≥ 3.0) bands. Samples are
    /// gated against the pressure stream one-to-one, so the
    /// fraction of samples in each band times total usage seconds
    /// approximates band seconds without us needing to know the
    /// PLD sample rate. Returns `(nil, nil)` when there is no
    /// snore signal for the night.
    private static func snoreBandSeconds(
        samples: [Double],
        usageMinutes: Double
    ) -> (moderate: Double?, loud: Double?) {
        guard !samples.isEmpty, usageMinutes > 0 else {
            return (nil, nil)
        }
        let total = Double(samples.count)
        let usageSeconds = usageMinutes * 60
        var moderate = 0
        var loud = 0
        for sample in samples {
            if sample >= 3.0 { loud += 1 }
            else if sample >= 1.5 { moderate += 1 }
        }
        return (
            moderate: Double(moderate) / total * usageSeconds,
            loud: Double(loud) / total * usageSeconds
        )
    }

    /// Linear-interpolated percentile. Returns `nil` for an empty input.
    private static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values[0] }
        var sorted = values
        sorted.sort()
        let rank = (p / 100) * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        let frac = rank - Double(low)
        return sorted[low] * (1 - frac) + sorted[high] * frac
    }

    /// Decode every record in a parsed `STR.edf` file into a `DailyStatistics`.
    /// Signals are looked up by label so the result survives firmware-dependent
    /// signal-order changes. `productName` is forwarded into each record so
    /// `modeName` can pick a device-specific label.
    public static func decode(
        from file: EDFFile,
        productName: String? = nil,
        isAirSense11: Bool = false
    ) throws -> [DailyStatistics] {
        var indexByLabel: [String: Int] = [:]
        for (i, signal) in file.signals.enumerated() {
            indexByLabel[signal.label] = i
        }

        // Decode each signal we care about once up-front.
        var cache: [Int: [Double]] = [:]
        func samples(_ label: String) -> [Double]? {
            guard let idx = indexByLabel[label] else { return nil }
            if let cached = cache[idx] { return cached }
            let decoded = (try? file.physicalSamples(ofSignal: idx)) ?? []
            cache[idx] = decoded
            return decoded
        }

        /// Reads the single-sample-per-record value for `label` in `record`,
        /// returning `nil` for the ResMed `-1` sentinel.
        func scalar(_ label: String, record: Int) -> Double? {
            guard let idx = indexByLabel[label],
                  let values = samples(label) else { return nil }
            let signal = file.signals[idx]
            let sliceStart = record * signal.samplesPerRecord
            guard sliceStart < values.count else { return nil }
            let value = values[sliceStart]
            return value < 0 ? nil : value
        }

        let calendar = Calendar.current
        var out: [DailyStatistics] = []
        out.reserveCapacity(max(0, file.header.recordCount))

        for record in 0..<file.header.recordCount {
            let recordStart = file.header.startDate.addingTimeInterval(
                Double(record) * file.header.recordDuration
            )
            let date = calendar.startOfDay(for: recordStart)

            // Leak values are stored in L/s; we expose L/min so the UI can
            // label them the way every other CPAP app does.
            let leak95 = scalar("Leak.95", record: record).map { $0 * 60 }
            let leakMax = scalar("Leak.Max", record: record).map { $0 * 60 }

            out.append(
                DailyStatistics(
                    date: date,
                    usageMinutes: scalar("Duration", record: record) ?? 0,
                    maskEvents: Int(scalar("MaskEvents", record: record) ?? 0),
                    ahi: scalar("AHI", record: record) ?? 0,
                    hypopneaIndex: scalar("HI", record: record) ?? 0,
                    apneaIndex: scalar("AI", record: record) ?? 0,
                    obstructiveApneaIndex: scalar("OAI", record: record) ?? 0,
                    centralApneaIndex: scalar("CAI", record: record) ?? 0,
                    unspecifiedApneaIndex: scalar("UAI", record: record) ?? 0,
                    pressureMedian: scalar("MaskPress.50", record: record),
                    pressure95: scalar("MaskPress.95", record: record),
                    pressureMax: scalar("MaskPress.Max", record: record),
                    ipap95: scalar("TgtIPAP.95", record: record),
                    epap95: scalar("TgtEPAP.95", record: record),
                    leak95LPerMin: leak95,
                    leakMaxLPerMin: leakMax,
                    flowLimit95: scalar("FlowLim.95", record: record),
                    minuteVentilation50: scalar("MinVent.50", record: record),
                    respirationRate50: scalar("RespRate.50", record: record),
                    tidalVolume50: scalar("TidVol.50", record: record),
                    modeCode: scalar("Mode", record: record).map { rawMode in
                        // AirSense 11 emits its own mode enum —
                        // route through `DeviceSettings.decode`
                        // below to stay in AS10 codes for the UI.
                        let raw = Int(rawMode)
                        guard isAirSense11 else { return raw }
                        switch raw {
                        case 1: return 1
                        case 2: return 3
                        case 3: return 7
                        default: return raw
                        }
                    },
                    productName: productName
                )
            )
            // Settings live on the per-record scalars alongside the
            // aggregate signals — pull them in via the same reader.
            out[out.count - 1].settings = DeviceSettings.decode(
                isAirSense11: isAirSense11
            ) { label in
                scalar(label, record: record)
            }
        }
        return out
    }
}

public extension DailyStatistics {
    /// AHI as it should appear in the UI given the user's CA-display
    /// preference. When the user has chosen to hide CA events, the
    /// central component is subtracted so the headline number reflects
    /// only obstructive + hypopnea + unspecified events. The stored
    /// `ahi` is left untouched — this is a display-time projection so
    /// the canonical device/computed value stays a single source of
    /// truth in the cache.
    func displayedAHI(includingCentral: Bool) -> Double {
        includingCentral ? ahi : max(0, ahi - centralApneaIndex)
    }

    /// CA index as it should appear in charts and stat-card stacks.
    /// Zeroed out when the user has hidden CA events so the segment
    /// drops out of stacked-bar denominators without callers having
    /// to special-case the preference at every site.
    func displayedCentralApneaIndex(visible: Bool) -> Double {
        visible ? centralApneaIndex : 0
    }
}
