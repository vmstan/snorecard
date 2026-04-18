import SwiftUI
import AppKit

/// Quit the app when the user closes its only window. Standard macOS
/// behavior leaves the process running in the Dock — not what a
/// single-window data viewer like Snorecard should do.
final class SnorecardAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Notification bridges between the macOS File menu and the
/// `ContentView` state that drives the confirm-dialog / rename
/// sheet. Keeping them as notifications (instead of plumbing
/// bindings through `@Environment`) keeps the menu declaration
/// flat and avoids leaking UI state up into `SnorecardApp`.
extension Notification.Name {
    static let snorecardRenameDevice = Notification.Name("Snorecard.RenameDevice")
    static let snorecardRebuildStatistics = Notification.Name("Snorecard.RebuildStatistics")
    static let snorecardShowBackups = Notification.Name("Snorecard.ShowBackups")
}

/// Codable payload threaded through SwiftUI's `openWindow(value:)`
/// API so the macOS Rename Device window can render without a
/// shared mutable state container. Carries the device's serial
/// (the source of truth for the alias map), the current alias,
/// and the marketing product name to seed the field.
struct RenameDeviceWindowPayload: Hashable, Codable, Identifiable {
    let serial: String
    let defaultName: String
    let currentOverride: String?

    var id: String { serial }
}

@main
struct SnorecardApp: App {
    @NSApplicationDelegateAdaptor(SnorecardAppDelegate.self) private var appDelegate
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    library.loadLastOpenedIfPossible()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                fileCommands
            }
        }

        // Standalone window opened from the Daily view's
        // "Detailed Statistics" button. Each invocation creates
        // a window keyed on the payload's day date so opening
        // the same night twice reuses the existing window
        // instead of stacking duplicates.
        WindowGroup(for: DetailedStatisticsPayload.self) { $payload in
            if let payload {
                DetailedStatisticsView(payload: payload)
                    .padding(20)
                    .frame(minWidth: 460, minHeight: 360)
                    .disableNonCloseWindowButtons()
            }
        }
        .windowResizability(.contentSize)

        // Singleton Backup & Restore window — replaces the
        // macOS sheet so the panel shows traffic-light
        // controls. Minimize / zoom are disabled so only the
        // red close button is active, Spotlight-style.
        Window("Backup & Restore", id: "backups") {
            BackupsView()
                .environment(library)
                .frame(minWidth: 460, minHeight: 380)
                .disableNonCloseWindowButtons()
        }
        .windowResizability(.contentSize)

        // Rename Device window — keyed on serial via the
        // payload so opening rename for the same device twice
        // reuses the existing window. Library is injected so
        // the view can call `setDeviceName` directly.
        WindowGroup(for: RenameDeviceWindowPayload.self) { $payload in
            if let payload {
                RenameDeviceSheet(
                    serial: payload.serial,
                    defaultName: payload.defaultName,
                    currentOverride: payload.currentOverride,
                    onSave: { newName in
                        library.setDeviceName(newName, for: payload.serial)
                    }
                )
                .frame(minWidth: 380, minHeight: 320)
                .disableNonCloseWindowButtons()
            }
        }
        .windowResizability(.contentSize)
    }

    /// Full File-menu command stack — mirrors the in-app Actions
    /// menu so users who instinctively reach for the menu bar get
    /// the same surface.
    @ViewBuilder
    private var fileCommands: some View {
        let hasCard = library.card?.identification?.serialNumber != nil
        let currentSerial = library.card?.identification?.serialNumber
        let otherDevices = Library.iCloudDeviceFolders().filter { folder in
            folder.serial != currentSerial
        }

        Button {
            library.reloadCurrent()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(!hasCard)

        Button {
            if let url = presentFolderPicker(
                prompt: "Open",
                message: "Select a CPAP SD card or DATALOG export folder"
            ) {
                library.load(url)
            }
        } label: {
            Label("Import SD Card", systemImage: "sdcard")
        }
        .keyboardShortcut("o", modifiers: [.command])

        Divider()

        Button {
            NotificationCenter.default.post(name: .snorecardRenameDevice, object: nil)
        } label: {
            Label("Rename Device", systemImage: "pencil")
        }
        .disabled(!hasCard)

        if !otherDevices.isEmpty {
            Menu {
                ForEach(otherDevices) { folder in
                    Button(menuLabel(for: folder)) {
                        library.load(folder.url)
                    }
                }
            } label: {
                Label("Switch Device", systemImage: "rectangle.2.swap")
            }
        }

        Divider()

        Button {
            NotificationCenter.default.post(name: .snorecardShowBackups, object: nil)
        } label: {
            Label("Backup & Restore", systemImage: "externaldrive.badge.timemachine")
        }
        .disabled(!hasCard)

        Button(role: .destructive) {
            NotificationCenter.default.post(name: .snorecardRebuildStatistics, object: nil)
        } label: {
            Label("Rebuild Statistics", systemImage: "hammer")
        }
        .disabled(!hasCard)
    }

    /// Alias-aware label for the Switch Device submenu — mirrors
    /// `ContentView.deviceMenuLabel(for:)` so the two menus read
    /// identically.
    private func menuLabel(for folder: Library.DeviceFolder) -> String {
        if let override = library.deviceNameOverrides[folder.serial], !override.isEmpty {
            return "\(override) (\(folder.serial))"
        }
        if let product = folder.productName, !product.isEmpty {
            return "\(product) (\(folder.serial))"
        }
        return "Device \(folder.serial)"
    }
}
