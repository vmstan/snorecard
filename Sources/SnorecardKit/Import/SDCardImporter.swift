import Foundation

/// One raw EDF file belonging to a session, discovered on the SD card.
public struct ResMedDataFile: Sendable, Equatable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let kind: ResMedFileKind
    /// Timestamp embedded in the filename (`YYYYMMDD_HHMMSS`), in device-local time.
    public let timestamp: Date?
    /// Size of the file on disk, or `nil` if unknown. Used to pick the main
    /// session of a day (largest file wins).
    public let byteSize: Int?
}

/// All files recorded on a single calendar day (`DATALOG/YYYYMMDD`).
public struct ResMedDay: Sendable, Equatable, Identifiable {
    public var id: Date { date }
    /// Midnight of the day, in device-local time.
    public let date: Date
    public let files: [ResMedDataFile]
    /// Aggregate statistics for this day, parsed from `STR.edf`. `nil` when
    /// the summary file either didn't cover this date or couldn't be decoded.
    public let stats: DailyStatistics?

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
public struct ResMedSDCard: Sendable, Equatable {
    public let rootURL: URL
    public let identification: ResMedIdentification?
    public let summaryFileURL: URL?
    public let days: [ResMedDay]
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
    /// Scan an SD card root and build an inventory of days and files.
    /// The scanner does not read EDF contents — it only inspects filenames.
    public static func scan(_ root: URL) throws -> ResMedSDCard {
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

        // Decode STR.edf once up front so every day can see if it has
        // pre-computed summary stats available.
        var statsByDate: [Date: DailyStatistics] = [:]
        if let summaryURL,
           let strFile = try? EDFFile(contentsOf: summaryURL),
           let decoded = try? DailyStatistics.decode(
               from: strFile,
               productName: identification?.productName
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

        let productName = identification?.productName

        // Process each day folder concurrently. Each task is
        // independent — they don't share mutable state — so a
        // `TaskGroup` gives a near-linear speedup on multi-core
        // machines.
        let days: [ResMedDay] = importDaysConcurrently(
            dayDirs: dayDirs,
            statsByDate: statsByDate,
            productName: productName
        )

        return ResMedSDCard(
            rootURL: root,
            identification: identification,
            summaryFileURL: summaryURL,
            days: days
        )
    }

    /// Wraps a `TaskGroup` that processes day folders in parallel and
    /// returns them sorted back into calendar order.
    private static func importDaysConcurrently(
        dayDirs: [URL],
        statsByDate: [Date: DailyStatistics],
        productName: String?
    ) -> [ResMedDay] {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var collected: [ResMedDay] = []
        Task.detached(priority: .userInitiated) {
            var result: [ResMedDay] = []
            await withTaskGroup(of: ResMedDay?.self) { group in
                for dir in dayDirs {
                    group.addTask {
                        await importDay(
                            dir: dir,
                            statsByDate: statsByDate,
                            productName: productName
                        )
                    }
                }
                for await day in group {
                    if let day { result.append(day) }
                }
            }
            result.sort { $0.date < $1.date }
            collected = result
            semaphore.signal()
        }
        semaphore.wait()
        return collected
    }

    /// Build one day's `ResMedDay`, using the sidecar stats cache when
    /// valid and falling back to the full `DailyStatistics.aggregate`
    /// pass otherwise. Writes the sidecar back out so the next launch
    /// hits the cache.
    private static func importDay(
        dir: URL,
        statsByDate: [Date: DailyStatistics],
        productName: String?
    ) async -> ResMedDay? {
        let fm = FileManager.default
        let name = dir.lastPathComponent
        guard let date = parseFolderDate(name) else { return nil }

        let files: [ResMedDataFile] = ((try? fm.contentsOfDirectory(
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

        let fingerprint = DailyStatsCache.Fingerprint.build(for: files)

        // Fast path — sidecar hit. Skip all EDF decoding.
        if let cached = DailyStatsCache.load(for: dir, fingerprint: fingerprint) {
            return ResMedDay(date: date, files: files, stats: cached)
        }

        // Slow path — decode once through the unified aggregate.
        let placeholder = ResMedDay(date: date, files: files, stats: nil)
        var stats = DailyStatistics.aggregate(
            for: placeholder,
            productName: productName
        )
        // If the STR.edf had a record for this day, prefer its
        // mode/maskEvents/etc. but keep the PLD-measured percentiles
        // and Glasgow Index from the aggregate pass.
        if let direct = statsByDate[date], stats != nil {
            stats = mergeSTRWithAggregate(str: direct, aggregate: stats!)
        }

        if let finalStats = stats {
            DailyStatsCache.save(finalStats, to: dir, fingerprint: fingerprint)
        }
        return ResMedDay(date: date, files: files, stats: stats)
    }

    /// STR.edf provides a few fields we can't derive from raw files
    /// (mode code, mask-on event counts). Keep those, but let the
    /// aggregate pass override everything else since its values match
    /// OSCAR / SleepHQ.
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
