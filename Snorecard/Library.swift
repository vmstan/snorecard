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

    private static let lastPathKey = "SnorecardLastSDPath"

    var card: ResMedSDCard? {
        if case .loaded(let card) = state { return card }
        return nil
    }

    var selectedDay: ResMedDay? {
        guard let card, case .day(let id) = selection else { return nil }
        return card.days.first { $0.id == id }
    }

    /// Auto-load data on launch. Tries iCloud first (the most up-to-date
    /// synced copy), then falls back to the last-opened local path.
    func loadLastOpenedIfPossible() {
        guard case .empty = state else { return }

        // Prefer iCloud — pick the most recently modified device folder.
        if let url = Self.bestICloudDeviceFolder() {
            load(url)
            return
        }

        // Fall back to whatever the user last opened locally.
        guard
            let path = UserDefaults.standard.string(forKey: Self.lastPathKey),
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else { return }
        load(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Returns the best device folder inside the iCloud backup root, or
    /// `nil` when iCloud isn't available or no backups exist yet. When
    /// multiple device folders exist the most recently modified one wins.
    private static func bestICloudDeviceFolder() -> URL? {
        guard let backupRoot = iCloudBackupRoot else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupRoot.path) else { return nil }

        let subfolders = ((try? fm.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        guard !subfolders.isEmpty else { return nil }

        return subfolders
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .first
    }

    func load(_ url: URL) {
        state = .loading(url)
        let source = CardSource.detect(from: url)
        Task.detached { [weak self] in
            do {
                let card = try SDCardImporter.scan(url)
                await MainActor.run {
                    UserDefaults.standard.set(url.path, forKey: Self.lastPathKey)
                    self?.state = .loaded(card)
                    // Default to the overview so the trends show immediately.
                    // Fall back to the latest day when there's no summary data.
                    if card.days.contains(where: { $0.stats?.hasUsage == true }) {
                        self?.selection = .overview
                    } else if let fallback = card.days.last(where: { !$0.files.isEmpty })?.id {
                        self?.selection = .day(fallback)
                    } else {
                        self?.selection = nil
                    }

                    // Auto-sync SD card imports to iCloud so the cloud
                    // copy stays up to date without manual intervention.
                    if source == .sdCard {
                        self?.syncToICloud()
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

    /// Sync the currently loaded data into Snorecard's iCloud ubiquity
    /// container, keyed on the device's serial number so iCloud keeps a
    /// single "latest" snapshot per CPAP machine. The container is marked
    /// as document-scope public in Info.plist, so the resulting folder
    /// shows up in Files / Finder under **iCloud Drive > Snorecard**.
    private func syncToICloud() {
        guard let card else { return }

        guard let backupRoot = Self.iCloudBackupRoot else { return }

        do {
            try FileManager.default.createDirectory(
                at: backupRoot,
                withIntermediateDirectories: true
            )
        } catch {
            return
        }

        let deviceFolder = backupRoot.appendingPathComponent(
            iCloudDeviceFolderName(for: card),
            isDirectory: true
        )

        let sourceURL = card.rootURL
        Task.detached {
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: deviceFolder.path) {
                    try fm.removeItem(at: deviceFolder)
                }

                try fm.createDirectory(
                    at: deviceFolder,
                    withIntermediateDirectories: true
                )

                let entries = try fm.contentsOfDirectory(
                    at: sourceURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for entry in entries {
                    let dest = deviceFolder.appendingPathComponent(entry.lastPathComponent)
                    try fm.copyItem(at: entry, to: dest)
                }
            } catch {
                // iCloud sync is best-effort; failures are silent.
            }
        }
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
    private func iCloudDeviceFolderName(for card: ResMedSDCard) -> String {
        card.identification?.serialNumber.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Unknown Device"
    }
}
