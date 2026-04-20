import Foundation

/// Eager-download helper for iCloud Drive. iOS presents files living
/// inside a ubiquity container lazily — `FileManager.contentsOfDirectory`
/// only returns entries whose metadata has already synced locally, so
/// folders and sidecars the Mac created may be invisible for a while.
///
/// To see *everything* iCloud knows about we query the ubiquity index
/// directly via `NSMetadataQuery`. That returns URLs for every matching
/// file in the container regardless of local cache state. We then
/// trigger downloads with `startDownloadingUbiquitousItem` and wait
/// for them to land so the import path can hit the sidecar cache.
public enum CloudPrefetcher {

    public struct Progress: Sendable, Equatable {
        public let completed: Int
        public let total: Int
    }

    /// Discover every sidecar via iCloud's index, kick off downloads
    /// for any that aren't already readable, and wait for them to
    /// arrive. Reports counts via the `progress` callback each time
    /// the download status changes.
    public static func prefetchSidecars(
        in deviceFolder: URL,
        timeout: TimeInterval = 600,
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async {
        // Fast path — if every day folder we can already see has a
        // locally-readable sidecar and no placeholder files, skip the
        // `NSMetadataQuery` dance entirely. This is the common case on
        // a launch where nothing has changed remotely since last time.
        if localSidecarsAllReadable(in: deviceFolder) {
            await progress(Progress(completed: 0, total: 0))
            return
        }

        // Ask iCloud's server-side index for every sidecar under the
        // device folder — including entries iOS hasn't materialized
        // in its local directory listings yet.
        let discovered = await MetadataDiscovery.run(
            in: deviceFolder,
            fsNameLike: DailyStatsCache.filename
        )

        let fm = FileManager.default
        var pending: [URL] = []
        for url in discovered {
            guard !isReadable(url) else { continue }
            try? fm.startDownloadingUbiquitousItem(at: url)
            pending.append(url)
        }

        let total = pending.count
        guard total > 0 else {
            await progress(Progress(completed: 0, total: 0))
            return
        }

        await progress(Progress(completed: 0, total: total))

        let start = Date()
        var lastReported = 0
        var lastChange = Date()
        while true {
            let completed = pending.reduce(into: 0) { count, url in
                if isReadable(url) { count += 1 }
            }
            if completed != lastReported {
                await progress(Progress(completed: completed, total: total))
                lastReported = completed
                lastChange = Date()
            }
            if completed >= total { break }
            if Date().timeIntervalSince(start) > timeout { break }
            // Bail after 45 s without any download finishing — the
            // remaining files can't be fetched right now. We'll
            // retrigger below so iCloud keeps them queued.
            if Date().timeIntervalSince(lastChange) > 45 { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Keep iCloud working on anything still not downloaded so a
        // subsequent launch can pick them up from cache.
        for url in pending where !isReadable(url) {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// `.current` (latest) and `.downloaded` (older but present) both
    /// mean the file can be read locally.
    private static func isReadable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else {
            // Non-ubiquity files report no status — treat as ready.
            return true
        }
        return status == .current || status == .downloaded
    }

    /// Filesystem-only scan — walk every day folder iOS has already
    /// materialized and confirm each `.snorecard-stats.json` sidecar
    /// is locally readable. Returns `false` the moment we see a day
    /// folder whose sidecar is missing or a placeholder. Doesn't
    /// know about day folders that haven't synced down yet; the
    /// full `NSMetadataQuery` path handles that case.
    private static func localSidecarsAllReadable(in deviceFolder: URL) -> Bool {
        let fm = FileManager.default
        let datalog = deviceFolder.appendingPathComponent("DATALOG", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: datalog.path, isDirectory: &isDir), isDir.boolValue else {
            // No DATALOG yet — nothing to fast-path over. Let the
            // slow path run; it'll handle the empty case fine.
            return false
        }
        guard let dayDirs = try? fm.contentsOfDirectory(
            at: datalog,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        // Short-circuit on the first folder that needs a remote
        // fetch. An empty DATALOG (no day folders) still counts as
        // "warm" — nothing to download.
        for dir in dayDirs {
            let isDirectory = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDirectory else { continue }
            let sidecar = dir.appendingPathComponent(DailyStatsCache.filename)
            if !fm.fileExists(atPath: sidecar.path) {
                // Missing sidecar. If the day has raw EDFs we'd want
                // to download one once iCloud produces it — defer to
                // the slow path so it can wait for the file to arrive.
                return false
            }
            if !isReadable(sidecar) {
                return false
            }
        }
        return true
    }
}

extension CloudPrefetcher {

    /// Fresh-install rescue path. When a user installs Snorecard on
    /// a new iPad/iPhone, the device folder may show up in
    /// `iCloudDeviceFolders` (the backup root itself has synced)
    /// while the DATALOG subfolders have not — `contentsOfDirectory`
    /// returns empty and `scanStructure` finishes with zero days.
    ///
    /// Query iCloud's index for raw `.edf` files under the device
    /// folder and trigger their download. That surfaces each day
    /// folder in local directory listings so a follow-up
    /// `scanStructure` pass picks them up. Non-blocking — we fire
    /// off `startDownloadingUbiquitousItem` for each match and let
    /// iCloud stream content in the background.
    public static func materializeDeviceTree(in deviceFolder: URL) async {
        let edfs = await MetadataDiscovery.run(
            in: deviceFolder,
            fsNameLike: "*.edf"
        )
        let fm = FileManager.default
        for url in edfs {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }
}

/// Wraps `NSMetadataQuery` to enumerate file URLs under a specific
/// device folder that match a filename predicate. The query runs on
/// the main actor because `NSMetadataQuery` requires a live run
/// loop and posts its notifications on `OperationQueue.main`.
@MainActor
private final class MetadataDiscovery {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<[URL], Never>?
    private let deviceFolderPath: String
    private let fsNameLike: String

    private init(deviceFolderPath: String, fsNameLike: String) {
        self.deviceFolderPath = deviceFolderPath
        self.fsNameLike = fsNameLike
    }

    /// Return every URL iCloud knows about inside the device folder
    /// whose filename matches `fsNameLike` (supports `*` wildcards).
    /// Waits up to 30 s for the initial metadata gather, plus a
    /// short settle window to catch late arrivals.
    static func run(in deviceFolder: URL, fsNameLike: String) async -> [URL] {
        // Resolve symlinks so path-prefix matching works even when
        // iCloud reports the container under its canonical path.
        let path = deviceFolder.resolvingSymlinksInPath().path
        return await MetadataDiscovery(
            deviceFolderPath: path,
            fsNameLike: fsNameLike
        ).start()
    }

    private func start() async -> [URL] {
        await withCheckedContinuation { cont in
            self.continuation = cont

            query.predicate = NSPredicate(
                format: "%K LIKE[cd] %@",
                NSMetadataItemFSNameKey,
                fsNameLike
            )
            #if os(iOS) || os(tvOS) || os(watchOS)
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            #else
            query.searchScopes = [
                NSMetadataQueryUbiquitousDocumentsScope,
                NSMetadataQueryUbiquitousDataScope
            ]
            #endif

            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Short settle window — give any trailing index
                    // updates a chance to land before we snapshot.
                    // Kept tight (400 ms) because the outer fast path
                    // already handled the "everything is warm" case;
                    // missed late arrivals will surface on next launch.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    self?.finish()
                }
            }

            // Hard timeout — if iCloud never finishes the initial
            // gather (offline, etc.) give up so the scan can proceed.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.finish()
            }

            query.start()
        }
    }

    private func finish() {
        guard let cont = continuation else { return }
        continuation = nil
        query.disableUpdates()
        query.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }

        var urls: [URL] = []
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
            else { continue }
            // Only accept results that actually live inside the
            // target device folder — iCloud's scope covers every
            // device, and we only want sidecars for the one we're
            // loading.
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(deviceFolderPath) else { continue }
            urls.append(url)
        }
        cont.resume(returning: urls)
    }
}
