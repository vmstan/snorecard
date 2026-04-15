import Foundation
import SnorecardKit
import Observation

/// Which section of the sidebar is active. An overview sits above all the days.
enum SidebarSelection: Hashable, Sendable {
    case overview
    case day(Date)
}

/// App-wide state: which SD card is loaded, which day is selected, and
/// whether a backup is currently in flight. Platform-agnostic — all picker
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

    enum BackupState: Equatable {
        case idle
        case running(subfolderName: String)
        case completed(URL)
        case failed(String)
    }

    var state: LoadState = .empty
    var selection: SidebarSelection? = nil
    var backup: BackupState = .idle

    private static let lastPathKey = "SnorecardLastSDPath"

    var card: ResMedSDCard? {
        if case .loaded(let card) = state { return card }
        return nil
    }

    var selectedDay: ResMedDay? {
        guard let card, case .day(let id) = selection else { return nil }
        return card.days.first { $0.id == id }
    }

    /// Auto-load the SD card the user last opened, if the folder still exists.
    /// Called on app launch so a normal session lands straight on the Overview.
    func loadLastOpenedIfPossible() {
        guard case .empty = state else { return }
        guard
            let path = UserDefaults.standard.string(forKey: Self.lastPathKey),
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else { return }
        load(URL(fileURLWithPath: path, isDirectory: true))
    }

    func load(_ url: URL) {
        state = .loading(url)
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
                }
            } catch {
                await MainActor.run {
                    self?.state = .failed(String(describing: error))
                }
            }
        }
    }

    // MARK: - Backup

    /// Back up the currently loaded SD card into a timestamped subfolder of
    /// `destination`. No-op if nothing is loaded. The caller provides the
    /// destination — picker UI lives in the view layer. Refuses to overwrite
    /// an existing backup with the same name.
    func startBackup(to destination: URL) {
        guard let card else { return }
        let subfolder = timestampedSubfolderName(for: card)
        let backupURL = destination.appendingPathComponent(subfolder, isDirectory: true)
        performBackup(card: card, destination: backupURL, replacingExisting: false)
    }

    /// Back up the currently loaded SD card into Snorecard's iCloud
    /// ubiquity container, keyed on the device's serial number so iCloud
    /// keeps a single "latest" snapshot per CPAP machine rather than
    /// accumulating timestamped copies. The container is marked as
    /// document-scope public in Info.plist, so the resulting folder
    /// shows up in Files / Finder under **iCloud Drive → Snorecard**.
    func startBackupToICloudDrive() {
        guard let card else { return }

        guard let backupRoot = Self.iCloudBackupRoot else {
            backup = .failed(
                "iCloud Drive isn't set up, or Snorecard's iCloud container hasn't finished initialising yet. Enable iCloud Drive in System Settings and try again."
            )
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: backupRoot,
                withIntermediateDirectories: true
            )
        } catch {
            backup = .failed("Couldn't create iCloud Drive folder: \(error.localizedDescription)")
            return
        }

        let deviceFolderName = iCloudDeviceFolderName(for: card)
        let deviceFolder = backupRoot.appendingPathComponent(deviceFolderName, isDirectory: true)
        performBackup(card: card, destination: deviceFolder, replacingExisting: true)
    }

    /// Dismiss a completed / failed backup so the progress sheet can close.
    func dismissBackupStatus() {
        backup = .idle
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
    /// Files / Finder under **iCloud Drive → Snorecard**.
    static var iCloudDriveRoot: URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: iCloudContainerID)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Where per-device backups live inside the ubiquity container — at
    /// the moment this is the same as `iCloudDriveRoot`, but keeping it
    /// as a separate computed property leaves room to carve out
    /// subdirectories later (preferences, annotations, etc.).
    static var iCloudBackupRoot: URL? {
        iCloudDriveRoot
    }

    /// Copy a card's DATALOG tree into `destination`. When
    /// `replacingExisting` is true and the destination already exists, it's
    /// removed before the new copy is written — suitable for sync-style
    /// backups that always mirror the current SD card.
    private func performBackup(
        card: ResMedSDCard,
        destination: URL,
        replacingExisting: Bool
    ) {
        backup = .running(subfolderName: destination.lastPathComponent)

        let sourceURL = card.rootURL
        Task.detached { [weak self] in
            let fm = FileManager.default
            var createdFreshDestination = false
            do {
                if fm.fileExists(atPath: destination.path) {
                    if replacingExisting {
                        try fm.removeItem(at: destination)
                    } else {
                        throw NSError(
                            domain: "Snorecard.Backup",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey:
                                "A backup named \(destination.lastPathComponent) already exists at that destination."]
                        )
                    }
                }

                // Enumerate the SD root and copy each top-level entry,
                // skipping hidden macOS-system directories like
                // `.Spotlight-V100`, `.fseventsd`, and `.Trashes` that
                // `copyItem(at:to:)` can't read without special entitlements.
                try fm.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
                createdFreshDestination = true

                let entries = try fm.contentsOfDirectory(
                    at: sourceURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for entry in entries {
                    let dest = destination.appendingPathComponent(entry.lastPathComponent)
                    try fm.copyItem(at: entry, to: dest)
                }

                await MainActor.run { self?.backup = .completed(destination) }
            } catch {
                // Only roll back if we created the destination ourselves —
                // don't nuke a pre-existing folder after a partial failure.
                if createdFreshDestination {
                    try? fm.removeItem(at: destination)
                }
                await MainActor.run {
                    self?.backup = .failed(String(describing: error))
                }
            }
        }
    }

    /// Folder name for user-picked ("Back Up SD Card…") backups — includes a
    /// timestamp so repeated backups to the same destination stack up.
    private func timestampedSubfolderName(for card: ResMedSDCard) -> String {
        let productName = card.identification?.productName ?? "ResMed"
        let serial = card.identification?.serialNumber ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let serialSuffix = serial.isEmpty ? "" : " \(serial)"
        return "\(productName)\(serialSuffix) \(timestamp)"
    }

    /// Folder name for iCloud Drive backups — keyed on serial only so a
    /// given device has exactly one folder that mirrors its current SD card.
    /// Falls back to `Unknown Device` when the SD card has no serial.
    private func iCloudDeviceFolderName(for card: ResMedSDCard) -> String {
        card.identification?.serialNumber.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Unknown Device"
    }
}
