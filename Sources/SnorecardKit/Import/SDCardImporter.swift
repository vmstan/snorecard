import Foundation

/// One raw EDF file belonging to a session, discovered on the SD card.
public struct ResMedDataFile: Sendable, Equatable, Identifiable, Codable {
    public var id: URL { url }
    public let url: URL
    public let kind: ResMedFileKind
    /// Timestamp embedded in the filename (`YYYYMMDD_HHMMSS`), in device-local time.
    public let timestamp: Date?
    /// Size of the file on disk, or `nil` if unknown. Used to pick the main
    /// session of a day (largest file wins).
    public let byteSize: Int?

    public init(url: URL, kind: ResMedFileKind, timestamp: Date?, byteSize: Int?) {
        self.url = url
        self.kind = kind
        self.timestamp = timestamp
        self.byteSize = byteSize
    }
}

/// All files recorded on a single calendar day (`DATALOG/YYYYMMDD`).
public struct ResMedDay: Sendable, Equatable, Identifiable, Codable {
    public var id: Date { date }
    /// Midnight of the day, in device-local time.
    public let date: Date
    public let files: [ResMedDataFile]
    /// Aggregate statistics for this day, parsed from `STR.edf`. `nil` when
    /// the summary file either didn't cover this date or couldn't be decoded.
    public var stats: DailyStatistics?

    public init(date: Date, files: [ResMedDataFile], stats: DailyStatistics?) {
        self.date = date
        self.files = files
        self.stats = stats
    }

    public func files(of kind: ResMedFileKind) -> [ResMedDataFile] {
        files.filter { $0.kind == kind }
    }

    /// The largest file of `kind` on this day, treating missing sizes as zero.
    /// Ties break on filename to stay deterministic.
    public func largestFile(of kind: ResMedFileKind) -> ResMedDataFile? {
        files(of: kind).max { lhs, rhs in
            let l = lhs.byteSize ?? 0
            let r = rhs.byteSize ?? 0
            if l != r { return l < r }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
    }
}

/// Top-level result of scanning an SD card root directory.
public struct ResMedSDCard: Sendable, Equatable, Codable {
    public let rootURL: URL
    public let identification: ResMedIdentification?
    public let summaryFileURL: URL?
    public var days: [ResMedDay]

    public init(
        rootURL: URL,
        identification: ResMedIdentification?,
        summaryFileURL: URL?,
        days: [ResMedDay]
    ) {
        self.rootURL = rootURL
        self.identification = identification
        self.summaryFileURL = summaryFileURL
        self.days = days
    }

    /// Return a copy with `day` substituted in for whichever existing day
    /// has the matching `id`. Silently no-ops if no day with that id
    /// exists (e.g. the card was swapped mid-backfill).
    public func replacing(day: ResMedDay) -> ResMedSDCard {
        var copy = self
        if let idx = copy.days.firstIndex(where: { $0.id == day.id }) {
            copy.days[idx] = day
        }
        return copy
    }
}

public enum SDCardImportError: Error, CustomStringConvertible {
    case notADirectory(URL)
    case missingDataLog(URL)

    public var description: String {
        switch self {
        case .notADirectory(let url):
            return "Not a directory: \(url.path)"
        case .missingDataLog(let url):
            return "No DATALOG directory under \(url.path)"
        }
    }
}

public enum SDCardImporter {
    /// Scan an SD card root and build an inventory of days and files,
    /// producing fully-aggregated statistics for each day. This is the
    /// legacy one-shot entry point — it's implemented as
    /// `scanStructure` + a synchronous drain of `backfillStats`, so it
    /// still returns a fully-populated card for callers (like
    /// `SnorecardProbe`) that don't want progressive updates.
    public static func scan(_ root: URL) throws -> ResMedSDCard {
        var card = try scanStructure(root)
        let productName = card.identification?.productName
        let updates = backfillStatsSync(for: card, productName: productName)
        for day in updates {
            card = card.replacing(day: day)
        }
        return card
    }

    /// Quick filesystem-only scan. Returns a `ResMedSDCard` populated
    /// with day folders + file inventories, and per-day `stats` pulled
    /// from the sidecar cache when available (falling back to the
    /// STR-only summary record when the cache hasn't been written yet).
    /// Skips every expensive PLD/BRP/EVE aggregate pass — use
    /// `backfillStats` to fill the remaining days in.
    public static func scanStructure(_ root: URL) throws -> ResMedSDCard {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw SDCardImportError.notADirectory(root)
        }

        let datalog = root.appendingPathComponent("DATALOG", isDirectory: true)
        guard fm.fileExists(atPath: datalog.path, isDirectory: &isDir), isDir.boolValue else {
            throw SDCardImportError.missingDataLog(root)
        }

        let identification: ResMedIdentification? = {
            guard let url = ResMedIdentification.locate(in: root) else { return nil }
            return try? ResMedIdentification(contentsOf: url)
        }()

        let strURL = root.appendingPathComponent("STR.edf")
        let summaryURL = fm.fileExists(atPath: strURL.path) ? strURL : nil

        // Decode STR.edf once up front so every day can fall back to
        // its pre-computed summary when the sidecar cache hasn't been
        // written yet.
        var statsByDate: [Date: DailyStatistics] = [:]
        if let summaryURL,
           let strFile = try? EDFFile(contentsOf: summaryURL),
           let decoded = try? DailyStatistics.decode(
               from: strFile,
               productName: identification?.productName,
               isAirSense11: identification?.isAirSense11 ?? false
           ) {
            for stats in decoded {
                statsByDate[stats.date] = stats
            }
        }

        let dayDirs = try fm.contentsOfDirectory(
            at: datalog,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let days: [ResMedDay] = dayDirs
            .compactMap { dir in
                structureDay(dir: dir, statsByDate: statsByDate)
            }
            .sorted { $0.date < $1.date }

        return ResMedSDCard(
            rootURL: root,
            identification: identification,
            summaryFileURL: summaryURL,
            days: days
        )
    }

    /// Streaming backfill — for each day that still needs full stats
    /// (sidecar cache missed during `scanStructure`), run the
    /// `DailyStatistics.aggregate` / STR merge / sidecar save pipeline
    /// and emit the refreshed `ResMedDay` via `onDay`.
    ///
    /// Callback is awaited serially per day, so the caller controls
    /// throttling / publishing cadence from the outside.
    public static func backfillStats(
        for card: ResMedSDCard,
        productName: String?,
        onDay: @MainActor @Sendable (ResMedDay) async -> Void
    ) async {
        // Rebuild the STR map from the card so merges can still run.
        // Cheap — a single EDF header + signal decode.
        let statsByDate = decodeSTR(
            summaryURL: card.summaryFileURL,
            productName: productName,
            isAirSense11: card.identification?.isAirSense11 ?? false
        )

        let candidates = card.days.filter { needsBackfill($0) }

        // Concurrent per-day work with bounded parallelism — each day
        // is independent, matching the original `TaskGroup` shape.
        let results: [ResMedDay] = await withTaskGroup(of: ResMedDay?.self) { group in
            for day in candidates {
                group.addTask {
                    aggregateDay(
                        day: day,
                        statsByDate: statsByDate,
                        productName: productName
                    )
                }
            }
            var collected: [ResMedDay] = []
            for await updated in group {
                if let updated { collected.append(updated) }
            }
            // Deterministic oldest-first emit so the sidebar fills in
            // chronological order.
            return collected.sorted { $0.date < $1.date }
        }

        for updated in results {
            await onDay(updated)
        }
    }

    /// Synchronous variant used by `scan(_:)` so non-async callers
    /// (e.g. `SnorecardProbe`) keep their one-shot behaviour.
    private static func backfillStatsSync(
        for card: ResMedSDCard,
        productName: String?
    ) -> [ResMedDay] {
        let statsByDate = decodeSTR(
            summaryURL: card.summaryFileURL,
            productName: productName,
            isAirSense11: card.identification?.isAirSense11 ?? false
        )
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var collected: [ResMedDay] = []
        Task.detached(priority: .userInitiated) {
            let candidates = card.days.filter { needsBackfill($0) }
            var result: [ResMedDay] = []
            await withTaskGroup(of: ResMedDay?.self) { group in
                for day in candidates {
                    group.addTask {
                        aggregateDay(
                            day: day,
                            statsByDate: statsByDate,
                            productName: productName
                        )
                    }
                }
                for await updated in group {
                    if let updated { result.append(updated) }
                }
            }
            result.sort { $0.date < $1.date }
            collected = result
            semaphore.signal()
        }
        semaphore.wait()
        return collected
    }

    /// Decode STR.edf into a `date → DailyStatistics` map, or an empty
    /// map on any failure. Identical work to what `scanStructure` does
    /// up front — repeated here so backfill can run against a card
    /// object it didn't build itself (e.g. a snapshot hydrated from
    /// disk on launch).
    private static func decodeSTR(
        summaryURL: URL?,
        productName: String?,
        isAirSense11: Bool = false
    ) -> [Date: DailyStatistics] {
        guard let summaryURL,
              let strFile = try? EDFFile(contentsOf: summaryURL),
              let decoded = try? DailyStatistics.decode(
                  from: strFile,
                  productName: productName,
                  isAirSense11: isAirSense11
              )
        else { return [:] }
        var map: [Date: DailyStatistics] = [:]
        for stats in decoded {
            map[stats.date] = stats
        }
        return map
    }

    /// True when the day hasn't gone through the full aggregate pass
    /// yet — either `stats` is nil entirely, or the stats we have came
    /// from STR.edf alone (no PLD-derived percentiles).
    private static func needsBackfill(_ day: ResMedDay) -> Bool {
        guard let stats = day.stats else { return true }
        // STR-only fallback is recognisable by missing PLD percentiles —
        // flowLimit95, glasgowIndex, timeInApneaSeconds are all computed
        // from PLD/EVE inputs. Any one being present means we already
        // ran the aggregate pass (or a past aggregate was cached in the
        // sidecar).
        if stats.flowLimit95 != nil || stats.glasgowIndex != nil
            || stats.timeInApneaSeconds != nil || stats.largeLeakSeconds != nil {
            return false
        }
        return true
    }

    /// Build the structure-only entry for one day folder.
    private static func structureDay(
        dir: URL,
        statsByDate: [Date: DailyStatistics]
    ) -> ResMedDay? {
        let name = dir.lastPathComponent
        guard let date = parseFolderDate(name) else { return nil }
        let files = enumerateFiles(in: dir)
        let fingerprint = DailyStatsCache.Fingerprint.build(for: files)

        // Sidecar cache hit → use the cached aggregate, but top up
        // the settings block from the current STR.edf so fields we
        // added after the sidecar was written (e.g. Trigger, Cycle,
        // TiMin/TiMax, Rise Time, Antibacterial Filter) get filled
        // in instead of silently decoding as nil.
        if let cached = DailyStatsCache.load(for: dir, fingerprint: fingerprint) {
            var stats = cached
            if let strSettings = statsByDate[date]?.settings {
                let existing = cached.settings ?? DeviceSettings()
                let combined = existing.completingNils(from: strSettings)
                if combined != cached.settings {
                    stats.settings = combined
                    // Persist the topped-up sidecar so the next
                    // launch hits the cache cleanly instead of
                    // re-doing this merge every time.
                    DailyStatsCache.save(stats, to: dir, fingerprint: fingerprint)
                }
            }
            return ResMedDay(date: date, files: files, stats: stats)
        }
        // Otherwise fall back to whatever STR.edf already knows. The
        // backfill pass will replace this with a full aggregate later.
        return ResMedDay(date: date, files: files, stats: statsByDate[date])
    }

    /// Run the full PLD/EVE aggregate for one day, merge with STR, and
    /// persist the sidecar so the next launch hits the cache.
    private static func aggregateDay(
        day: ResMedDay,
        statsByDate: [Date: DailyStatistics],
        productName: String?
    ) -> ResMedDay? {
        let placeholder = ResMedDay(date: day.date, files: day.files, stats: nil)
        var stats = DailyStatistics.aggregate(
            for: placeholder,
            productName: productName
        )
        if let direct = statsByDate[day.date], stats != nil {
            stats = mergeSTRWithAggregate(str: direct, aggregate: stats!)
        }

        // Carry forward any settings we decoded on a previous import
        // but the current STR.edf no longer covers (or emits with a
        // subset of signals). The `completingNils` merge preserves
        // newer non-nil fields and only backfills the gaps.
        let dir = day.files.first?.url.deletingLastPathComponent()
        if let dir,
           let previous = DailyStatsCache.loadAnyStats(for: dir)?.settings,
           stats != nil {
            let combined = (stats?.settings ?? DeviceSettings())
                .completingNils(from: previous)
            stats?.settings = combined.hasAnyValue ? combined : nil
        }

        if let finalStats = stats, let dir {
            let fingerprint = DailyStatsCache.Fingerprint.build(for: day.files)
            DailyStatsCache.save(finalStats, to: dir, fingerprint: fingerprint)
        }
        return ResMedDay(date: day.date, files: day.files, stats: stats)
    }

    /// Enumerate every EDF file in `dir`, sorted by filename, as
    /// `ResMedDataFile` records. Filters out anything whose filename
    /// doesn't decode to a known `ResMedFileKind`.
    private static func enumerateFiles(in dir: URL) -> [ResMedDataFile] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "edf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> ResMedDataFile? in
                guard let kind = ResMedFileKind.from(filename: url.lastPathComponent) else {
                    return nil
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                return ResMedDataFile(
                    url: url,
                    kind: kind,
                    timestamp: parseFileTimestamp(url.lastPathComponent),
                    byteSize: size
                )
            }
    }

    /// STR.edf provides a few fields we can't derive from raw files
    /// (mode code, mask-on event counts, the full `S.*` settings
    /// block). Keep those, but let the aggregate pass override
    /// everything else since its PLD-derived values match OSCAR /
    /// SleepHQ.
    private static func mergeSTRWithAggregate(
        str: DailyStatistics,
        aggregate: DailyStatistics
    ) -> DailyStatistics {
        var merged = aggregate
        if merged.modeCode == nil {
            merged = DailyStatistics(
                date: merged.date,
                usageMinutes: merged.usageMinutes,
                maskEvents: str.maskEvents,
                ahi: merged.ahi,
                hypopneaIndex: merged.hypopneaIndex,
                apneaIndex: merged.apneaIndex,
                obstructiveApneaIndex: merged.obstructiveApneaIndex,
                centralApneaIndex: merged.centralApneaIndex,
                unspecifiedApneaIndex: merged.unspecifiedApneaIndex,
                pressureMedian: merged.pressureMedian,
                pressure95: merged.pressure95,
                pressureMax: merged.pressureMax,
                ipap95: merged.ipap95,
                epap95: merged.epap95,
                leak95LPerMin: merged.leak95LPerMin,
                leakMaxLPerMin: merged.leakMaxLPerMin,
                timeInApneaSeconds: merged.timeInApneaSeconds,
                largeLeakSeconds: merged.largeLeakSeconds,
                glasgowIndex: merged.glasgowIndex,
                flowLimit95: merged.flowLimit95,
                minuteVentilation50: merged.minuteVentilation50,
                respirationRate50: merged.respirationRate50,
                tidalVolume50: merged.tidalVolume50,
                modeCode: str.modeCode,
                productName: merged.productName
            )
            // Rebuilt struct above dropped back to the `snore95`
            // default — carry the PLD-derived value forward.
            merged.snore95 = aggregate.snore95
        }
        // Carry the STR-derived settings block through. Field-level
        // merge (rather than wholesale swap) so a newer STR record
        // that's missing a signal doesn't null out a field we
        // already had from an older record — the aggregate pass
        // can't re-derive the `S.*` block, so whatever we lose we
        // lose for good.
        switch (str.settings, merged.settings) {
        case (let new?, let old?):
            merged.settings = new.completingNils(from: old)
        case (let new?, nil):
            merged.settings = new
        case (nil, _):
            break // keep merged.settings as-is
        }
        return merged
    }

    private static func parseFolderDate(_ name: String) -> Date? {
        guard name.count == 8, Int(name) != nil else { return nil }
        // ResMed devices record wall-clock local time with no timezone metadata,
        // so we construct the date in the current local calendar. This keeps the
        // day label the user sees matching the date shown on the device.
        let calendar = Calendar.current
        let year = Int(name.prefix(4))!
        let month = Int(name.dropFirst(4).prefix(2))!
        let day = Int(name.dropFirst(6).prefix(2))!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func parseFileTimestamp(_ filename: String) -> Date? {
        // e.g. "20260414_223939_BRP.edf"
        let parts = filename.split(separator: "_")
        guard parts.count >= 2,
              parts[0].count == 8,
              parts[1].count == 6 else { return nil }
        let calendar = Calendar.current
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
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))
    }
}
