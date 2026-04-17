import Foundation
import SnorecardKit
import Observation

/// Which section of the sidebar is active. An overview sits above all the days.
enum SidebarSelection: Hashable, Sendable {
    case overview
    case day(Date)
}

/// App-wide state: which SD card is loaded, which day is selected, and
/// whether an iCloud sync is in flight. Platform-agnostic — all picker
/// UI lives in the view layer so this type can compile unchanged on
/// macOS, iOS, and iPadOS.
@Observable
@MainActor
final class Library {
    enum LoadState: Equatable {
        case empty
        case loading(URL)
        /// Transitional state — we have enough of the card to paint
        /// the sidebar (from either a persisted snapshot or a quick
        /// structure-only scan) but per-day aggregates are still
        /// filling in. Views treat this the same as `.loaded`.
        case hydrating(ResMedSDCard)
        case loaded(ResMedSDCard)
        case failed(String)
    }

    var state: LoadState = .empty
    var selection: SidebarSelection? = nil
    /// Map of CPAP serial number → custom display name. Backed by
    /// `NSUbiquitousKeyValueStore` so the override syncs automatically
    /// across all of the user's Macs and iOS devices.
    private(set) var deviceNameOverrides: [String: String] = [:]
    /// Non-nil while iCloud placeholder sidecars are being fetched so
    /// the sidebar can show a "Downloading from iCloud — N/M" hint
    /// instead of looking stuck.
    var cloudPrefetchProgress: CloudPrefetcher.Progress?

    private static let lastPathKey = "SnorecardLastSDPath"
    private static let deviceNamesKey = "deviceNameOverrides"
    private static let lastOpenedSerialKey = "lastOpenedSerial"

    init() {
        let kvs = NSUbiquitousKeyValueStore.default
        deviceNameOverrides = kvs.dictionary(forKey: Self.deviceNamesKey)
            as? [String: String] ?? [:]

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDeviceNameOverrides()
            }
        }
        // Kick off an initial pull so any value already synced to this
        // device is picked up on first launch.
        kvs.synchronize()
    }

    var card: ResMedSDCard? {
        switch state {
        case .loaded(let card), .hydrating(let card): return card
        default: return nil
        }
    }

    /// `true` while a progressive backfill is still in flight — used
    /// by views that want to show a subtle "finishing…" indicator.
    var isHydrating: Bool {
        if case .hydrating = state { return true }
        return false
    }

    var selectedDay: ResMedDay? {
        guard let card, case .day(let id) = selection else { return nil }
        return card.days.first { $0.id == id }
    }

    // MARK: - Device name overrides

    /// The user-facing name for a loaded card. Prefers the iCloud-synced
    /// override (keyed on serial), falling back to the ResMed product name
    /// and finally a generic label.
    func displayName(for card: ResMedSDCard) -> String {
        if let serial = card.identification?.serialNumber,
           let override = deviceNameOverrides[serial],
           !override.isEmpty {
            return override
        }
        return card.identification?.productName ?? "ResMed Device"
    }

    /// Set or clear a custom name for a given serial. Passing an empty /
    /// whitespace-only string removes the override.
    func setDeviceName(_ name: String?, for serial: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            deviceNameOverrides[serial] = trimmed
        } else {
            deviceNameOverrides.removeValue(forKey: serial)
        }
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.set(deviceNameOverrides, forKey: Self.deviceNamesKey)
        kvs.synchronize()
    }

    private func refreshDeviceNameOverrides() {
        let kvs = NSUbiquitousKeyValueStore.default
        deviceNameOverrides = kvs.dictionary(forKey: Self.deviceNamesKey)
            as? [String: String] ?? [:]
    }

    /// Re-run the scan on the currently loaded card's folder without
    /// discarding the cache. Picks up day folders and sidecars that
    /// have synced down from iCloud since the initial load.
    func reloadCurrent() {
        guard let url = card?.rootURL else { return }
        load(url)
    }

    /// Async variant of `reloadCurrent` that returns only once the
    /// load pipeline has settled (prefetch + scan + backfill all
    /// finished). Pull-to-refresh needs this shape so the spinner
    /// stays up through the refresh rather than dismissing the
    /// instant the detached task kicks off.
    func reloadCurrentAndWait() async {
        guard let url = card?.rootURL else { return }
        load(url)
        // Poll the `@Observable` state until it leaves the in-flight
        // cases. 150 ms is a comfortable balance between snappy
        // dismissal on fast refreshes and not churning the main run
        // loop on slow ones.
        while true {
            switch state {
            case .loaded, .failed, .empty:
                return
            case .loading, .hydrating:
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }


    /// Remove every `.snorecard-stats.json` sidecar inside the currently
    /// loaded card's DATALOG tree and trigger a full re-import. Forces
    /// the next scan to recompute every day from scratch — useful when
    /// the computation logic has changed or a day's cache got out of
    /// sync with the raw data.
    ///
    /// **Intentionally narrow:** this only removes files matching
    /// `DailyStatsCache.filename`. User-authored notes
    /// (`DailyNotesCache.filename`) must never be deleted by a
    /// rebuild — they aren't derived data and can't be recomputed.
    func invalidateStatsCacheAndReload() {
        guard let url = card?.rootURL else { return }
        let datalog = url.appendingPathComponent("DATALOG", isDirectory: true)
        let fm = FileManager.default
        if let dayDirs = try? fm.contentsOfDirectory(
            at: datalog,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for dir in dayDirs {
                let sidecar = dir.appendingPathComponent(DailyStatsCache.filename)
                try? fm.removeItem(at: sidecar)
            }
        }
        load(url)
    }

    // MARK: - Per-day notes

    /// Read the user-authored note for `day`, or `nil` when none
    /// exists / the day folder has no files to anchor a note to.
    func note(for day: ResMedDay) -> DailyNote? {
        guard let folder = day.files.first?.url.deletingLastPathComponent()
        else { return nil }
        return DailyNotesCache.load(for: folder)
    }

    /// Persist `text` as the note for `day`. A nil or whitespace-only
    /// string removes the note entirely. The `updatedAt` timestamp is
    /// stamped here so views don't need to care about it.
    func setNote(_ text: String?, for day: ResMedDay) {
        guard let folder = day.files.first?.url.deletingLastPathComponent()
        else { return }
        let raw = text ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DailyNotesCache.save(nil, to: folder)
        } else {
            DailyNotesCache.save(
                DailyNote(text: raw, updatedAt: Date()),
                to: folder
            )
        }
    }

    /// Auto-load data on launch. Tries to re-open the device the user
    /// last actively selected (persisted in iCloud KVS so it follows
    /// the user across Macs and iPhones). Falls back to the most
    /// recently modified iCloud folder, and finally to whatever was
    /// last opened locally.
    func loadLastOpenedIfPossible() {
        guard case .empty = state else { return }

        if let url = Self.preferredICloudDeviceFolder() {
            // Seed from the on-disk snapshot (keyed on serial, which
            // is the iCloud folder's last path component) so the
            // sidebar appears instantly — the subsequent `load` pass
            // refreshes days as they finish aggregating.
            let serial = url.lastPathComponent
            if let snapshot = CardSnapshot.load(forSerial: serial) {
                state = .hydrating(snapshot)
            }
            load(url)
            return
        }

        // Last resort — whatever path we stashed in UserDefaults
        // (used when iCloud is entirely unavailable).
        guard
            let path = UserDefaults.standard.string(forKey: Self.lastPathKey),
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else { return }
        load(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Pick the device folder to auto-load on launch. First priority
    /// is the serial the user last explicitly opened (synced via
    /// `NSUbiquitousKeyValueStore` so the choice persists between
    /// devices). If that serial's folder isn't here yet, fall back to
    /// the most recently modified folder.
    private static func preferredICloudDeviceFolder() -> URL? {
        let folders = iCloudDeviceFolders()
        guard !folders.isEmpty else { return nil }

        let kvs = NSUbiquitousKeyValueStore.default
        if let wanted = kvs.string(forKey: lastOpenedSerialKey),
           let match = folders.first(where: { $0.serial == wanted }) {
            return match.url
        }
        return folders.first?.url
    }

    /// Record a device's serial as the most recently opened one.
    /// Syncs via iCloud KVS so every device remembers the last
    /// selection across launches.
    fileprivate func rememberLastOpened(serial: String?) {
        let kvs = NSUbiquitousKeyValueStore.default
        if let serial, !serial.isEmpty {
            kvs.set(serial, forKey: Self.lastOpenedSerialKey)
        } else {
            kvs.removeObject(forKey: Self.lastOpenedSerialKey)
        }
        kvs.synchronize()
    }

    /// Summary of a device folder stored inside Snorecard's iCloud
    /// container. Presented to the user in the sidebar switcher so they
    /// can pick between machines without re-importing.
    struct DeviceFolder: Identifiable, Hashable, Sendable {
        let url: URL
        let serial: String
        /// Product name pulled from the folder's `Identification` file
        /// (e.g. "AirSense 10 AutoSet"). `nil` when the file is missing
        /// or can't be parsed.
        let productName: String?
        let modified: Date?
        var id: URL { url }
    }

    /// Every device folder inside the iCloud backup root, sorted most-
    /// recently-modified first. Empty when iCloud is unavailable.
    static func iCloudDeviceFolders() -> [DeviceFolder] {
        guard let backupRoot = iCloudBackupRoot else { return [] }
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupRoot.path) else { return [] }

        let subfolders = ((try? fm.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        return subfolders
            .map { url -> DeviceFolder in
                let productName: String? = {
                    guard let idURL = ResMedIdentification.locate(in: url),
                          let ident = try? ResMedIdentification(contentsOf: idURL)
                    else { return nil }
                    return ident.productName
                }()
                return DeviceFolder(
                    url: url,
                    serial: url.lastPathComponent,
                    productName: productName,
                    modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                )
            }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    func load(_ url: URL) {
        // If the sidebar already shows the device being loaded (via
        // a snapshot-seeded `.hydrating` state, or a prior `.loaded`
        // card being refreshed) preserve the visible day list so the
        // user doesn't get flashed a loading screen.
        let existingCard: ResMedSDCard? = {
            switch state {
            case .hydrating(let c), .loaded(let c): return c
            default: return nil
            }
        }()
        let preserveHydration: Bool = {
            guard let existing = existingCard else { return false }
            if existing.rootURL == url { return true }
            if existing.identification?.serialNumber == url.lastPathComponent {
                return true
            }
            return false
        }()

        if preserveHydration, let existing = existingCard {
            // Keep what the user sees on screen as the hydrating card
            // while we kick off a fresh scan in the background.
            state = .hydrating(existing)
        } else {
            state = .loading(url)
            #if os(iOS)
            // On iPhone NavigationSplitView is a stack — clear the
            // selection immediately so the detail pane pops back to
            // the sidebar instead of leaving the user stuck on a now-
            // stale Overview / Day view while the new device loads.
            selection = nil
            #endif
        }
        cloudPrefetchProgress = nil

        let source = CardSource.detect(from: url)
        Task.detached { [weak self] in
            // Eagerly download iCloud sidecar placeholders so the
            // scan hits its cache path for every day.
            if source == .iCloud {
                await CloudPrefetcher.prefetchSidecars(in: url) { progress in
                    await MainActor.run {
                        // Hide the indicator once everything has
                        // finished; keep it visible while downloading.
                        self?.cloudPrefetchProgress = progress.completed < progress.total
                            ? progress
                            : nil
                    }
                }
                await MainActor.run { self?.cloudPrefetchProgress = nil }
            }

            do {
                // Phase 1 — quick structure-only scan. Gives us the
                // day list and any sidecar-cached stats immediately.
                let structure = try SDCardImporter.scanStructure(url)

                // For SD card imports, merge new day folders into
                // iCloud first, then use the iCloud folder as the
                // canonical source so history accumulates there.
                var currentCard = structure
                var currentURL = url
                if source == .sdCard {
                    if let iCloudURL = await Self.mergeIntoICloud(
                        sourceURL: url,
                        card: structure
                    ) {
                        // Prefetch iCloud's view of this device so
                        // the re-scan sees every historical day, not
                        // just the ones we just copied off the SD.
                        // Critical on iPhone first-run imports where
                        // iOS hasn't materialized the device folder
                        // at all yet.
                        await CloudPrefetcher.prefetchSidecars(in: iCloudURL) { progress in
                            await MainActor.run {
                                self?.cloudPrefetchProgress = progress.completed < progress.total
                                    ? progress
                                    : nil
                            }
                        }
                        await MainActor.run { self?.cloudPrefetchProgress = nil }

                        if let merged = try? SDCardImporter.scanStructure(iCloudURL) {
                            currentCard = merged
                            currentURL = iCloudURL
                        }
                    }
                }

                // Publish the structure so the sidebar renders now,
                // before the aggregate backfill starts chewing EDFs.
                let seededCard = currentCard
                let persistedPath = currentURL.path
                let loadedSerial = seededCard.identification?.serialNumber
                await MainActor.run {
                    UserDefaults.standard.set(persistedPath, forKey: Self.lastPathKey)
                    self?.rememberLastOpened(serial: loadedSerial)
                    self?.state = .hydrating(seededCard)
                }

                // Phase 2 — stream per-day aggregates. Each callback
                // replaces one day's stats in place; the accumulated
                // card is the new canonical value until the final
                // `.loaded` transition below.
                let productName = seededCard.identification?.productName
                nonisolated(unsafe) var accumulated = seededCard
                await SDCardImporter.backfillStats(
                    for: seededCard,
                    productName: productName
                ) { @MainActor [weak self] updatedDay in
                    accumulated = accumulated.replacing(day: updatedDay)
                    // Keep publishing as `.hydrating` — the final
                    // `.loaded` transition runs once the group finishes.
                    self?.state = .hydrating(accumulated)
                }

                let finalCard = accumulated
                await MainActor.run {
                    self?.state = .loaded(finalCard)
                    // Persist snapshot so the next launch can paint
                    // the sidebar before any I/O completes.
                    CardSnapshot.save(finalCard)
                    self?.applyDefaultSelection(for: finalCard)
                }
            } catch {
                await MainActor.run {
                    self?.state = .failed(String(describing: error))
                }
            }
        }
    }

    /// Choose the detail-pane selection after a card finishes loading.
    /// On iOS we stay on the sidebar; on macOS we default to Overview
    /// (or the most recent day with raw files if STR.edf is empty).
    private func applyDefaultSelection(for card: ResMedSDCard) {
        #if os(iOS)
        // iOS NavigationSplitView is a stack — leaving selection nil
        // drops the user back on the sidebar rather than a stale
        // detail pane. Only clear if we weren't mid-drill-down via
        // the snapshot-hydration flow.
        if selection == nil { return }
        if case .day(let id) = selection,
           card.days.contains(where: { $0.id == id }) {
            return
        }
        selection = nil
        #else
        // macOS keeps the sidebar visible, so pre-select something
        // sensible — but don't override a selection the user already
        // made while the `.hydrating` state was up.
        if selection != nil { return }
        if card.days.contains(where: { $0.stats?.hasUsage == true }) {
            selection = .overview
        } else if let fallback = card.days.last(where: { !$0.files.isEmpty })?.id {
            selection = .day(fallback)
        } else {
            selection = nil
        }
        #endif
    }

    // MARK: - iCloud sync

    /// Merge a newly-imported SD card into Snorecard's iCloud ubiquity
    /// container. Day folders already present in iCloud are preserved
    /// so repeat imports accumulate history; top-level summary files
    /// (STR.edf, Identification.tgt, SETTINGS) are always refreshed.
    /// Returns the iCloud device-folder URL on success so the caller
    /// can re-scan it and present the combined dataset.
    private static func mergeIntoICloud(
        sourceURL: URL,
        card: ResMedSDCard
    ) async -> URL? {
        guard let backupRoot = iCloudBackupRoot else { return nil }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let deviceFolder = backupRoot.appendingPathComponent(
            Self.iCloudDeviceFolderName(for: card),
            isDirectory: true
        )

        return await Task.detached(priority: .userInitiated) { () -> URL? in
            do {
                if !fm.fileExists(atPath: deviceFolder.path) {
                    try fm.createDirectory(
                        at: deviceFolder,
                        withIntermediateDirectories: true
                    )
                }

                let topLevel = try fm.contentsOfDirectory(
                    at: sourceURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )

                for entry in topLevel {
                    let name = entry.lastPathComponent
                    let dest = deviceFolder.appendingPathComponent(name)

                    if name == "DATALOG" {
                        if !fm.fileExists(atPath: dest.path) {
                            try fm.createDirectory(
                                at: dest,
                                withIntermediateDirectories: true
                            )
                        }
                        let dayDirs = (try? fm.contentsOfDirectory(
                            at: entry,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        )) ?? []
                        for dayDir in dayDirs {
                            let dayDest = dest.appendingPathComponent(dayDir.lastPathComponent)
                            guard !fm.fileExists(atPath: dayDest.path) else { continue }
                            try? fm.copyItem(at: dayDir, to: dayDest)
                        }
                    } else {
                        if fm.fileExists(atPath: dest.path) {
                            try? fm.removeItem(at: dest)
                        }
                        try? fm.copyItem(at: entry, to: dest)
                    }
                }
                return deviceFolder
            } catch {
                // iCloud sync is best-effort; on failure the caller
                // falls back to showing just the SD card data.
                return nil
            }
        }.value
    }

    // MARK: - iCloud paths

    /// Bundle identifier for the shared Snorecard ubiquity container —
    /// declared in each target's `.entitlements` file and referenced by
    /// the ubiquity-container APIs below.
    static let iCloudContainerID = "iCloud.com.vmstan.Snorecard"

    /// On-disk URL of Snorecard's user-visible `Documents/` folder inside
    /// its iCloud ubiquity container, or `nil` when iCloud Drive isn't
    /// set up on this device. Because the container is declared as
    /// document-scope public in Info.plist, this folder shows up in
    /// Files / Finder under **iCloud Drive > Snorecard**.
    static var iCloudDriveRoot: URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: iCloudContainerID)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Where per-device syncs live inside the ubiquity container.
    static var iCloudBackupRoot: URL? {
        iCloudDriveRoot
    }

    /// Folder name for iCloud Drive syncs — keyed on serial only so a
    /// given device has exactly one folder that mirrors its current SD card.
    /// Falls back to `Unknown Device` when the SD card has no serial.
    private static func iCloudDeviceFolderName(for card: ResMedSDCard) -> String {
        card.identification?.serialNumber.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Unknown Device"
    }
}
