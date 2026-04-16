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
        if case .loaded(let card) = state { return card }
        return nil
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

    /// Remove every `.snorecard-stats.json` sidecar inside the currently
    /// loaded card's DATALOG tree and trigger a full re-import. Forces
    /// the next scan to recompute every day from scratch — useful when
    /// the computation logic has changed or a day's cache got out of
    /// sync with the raw data.
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

    /// Auto-load data on launch. Tries to re-open the device the user
    /// last actively selected (persisted in iCloud KVS so it follows
    /// the user across Macs and iPhones). Falls back to the most
    /// recently modified iCloud folder, and finally to whatever was
    /// last opened locally.
    func loadLastOpenedIfPossible() {
        guard case .empty = state else { return }

        if let url = Self.preferredICloudDeviceFolder() {
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
        state = .loading(url)
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
                let sdCard = try SDCardImporter.scan(url)

                // For SD card imports, merge new day folders into iCloud
                // and then re-scan iCloud so the view reflects the
                // combined history instead of only what was on the card.
                var finalCard = sdCard
                var finalURL = url
                if source == .sdCard {
                    if let iCloudURL = await Self.mergeIntoICloud(
                        sourceURL: url,
                        card: sdCard
                    ),
                       let merged = try? SDCardImporter.scan(iCloudURL) {
                        finalCard = merged
                        finalURL = iCloudURL
                    }
                }

                let loadedCard = finalCard
                let persistedPath = finalURL.path
                let loadedSerial = loadedCard.identification?.serialNumber
                await MainActor.run {
                    UserDefaults.standard.set(persistedPath, forKey: Self.lastPathKey)
                    self?.rememberLastOpened(serial: loadedSerial)
                    self?.state = .loaded(loadedCard)
                    // Default to the overview so the trends show immediately.
                    // Fall back to the latest day when there's no summary data.
                    if loadedCard.days.contains(where: { $0.stats?.hasUsage == true }) {
                        self?.selection = .overview
                    } else if let fallback = loadedCard.days.last(where: { !$0.files.isEmpty })?.id {
                        self?.selection = .day(fallback)
                    } else {
                        self?.selection = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self?.state = .failed(String(describing: error))
                }
            }
        }
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
