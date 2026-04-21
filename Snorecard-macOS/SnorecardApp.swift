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
    static let snorecardShowBackups = Notification.Name("Snorecard.ShowBackups")
    static let snorecardShowSettings = Notification.Name("Snorecard.ShowSettings")
    // Sleep Analysis and Rebuild Analysis are declared in the
    // shared ContentView notification set so both platforms
    // reference the same names; this extension only adds commands
    // that are macOS-only.
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
                    // Re-apply the last-selected alternate icon so
                    // the Dock picks it up on cold launch instead
                    // of flashing the primary icon and then
                    // swapping — UserDefaults is read synchronously
                    // so the swap happens before the first layout.
                    AppIconController.applyStoredOnLaunch()
                    await library.loadLastOpenedIfPossible()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                fileCommands
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .snorecardShowSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
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
                    .frame(minWidth: 460, minHeight: 620)
                    .disableNonCloseWindowButtons()
            }
        }
        .windowResizability(.contentSize)

        // Advanced Charting window — high-resolution breath
        // waveforms + session-timeline scrubber. Keyed on day
        // date (same convention as Detailed Statistics) so
        // opening the same night twice reuses the window
        // instead of stacking duplicates.
        WindowGroup(for: AdvancedChartingPayload.self) { $payload in
            if let payload {
                AdvancedChartingView(payload: payload)
                    .frame(minWidth: 960, minHeight: 640)
            }
        }
    }

    /// Full File-menu command stack — mirrors the in-app Actions
    /// ellipsis on iOS so users who reach for the menu bar get the
    /// same surface. Order follows the iOS menu verbatim, with
    /// Refresh kept at the top because ⌘R is a menu-bar staple the
    /// iOS surface has no equivalent for (it uses pull-to-refresh).
    @ViewBuilder
    private var fileCommands: some View {
        let hasCard = library.card?.identification?.serialNumber != nil
        let currentSerial = library.card?.identification?.serialNumber
        let otherDevices = Library.iCloudDeviceFolders().filter { folder in
            folder.serial != currentSerial
        }
        let isViewingDay: Bool = {
            if case .day = library.selection { return true }
            return false
        }()

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
                message: "Select a PAP-device SD card or DATALOG export folder"
            ) {
                library.load(url)
            }
        } label: {
            Label("Import SD Card", systemImage: "externaldrive.badge.plus")
        }
        .keyboardShortcut("o", modifiers: [.command])

        Divider()

        // Sleep Analysis covers both scopes: per-night on the day
        // view, per-range on the Overview. Posts whichever
        // notification matches the current selection, mirroring
        // how Sleep Journal swaps between daily / device notes.
        Button {
            NotificationCenter.default.post(
                name: isViewingDay ? .snorecardOpenSleepAnalysis : .snorecardOpenOverviewAnalysis,
                object: nil
            )
        } label: {
            Label("Sleep Analysis", systemImage: "sparkles")
        }
        .disabled(!hasCard || !library.intelligence.isReady)

        // Sleep Journal targets whichever scope the user is
        // currently viewing — the per-night journal from a day,
        // the device-wide journal from the Overview. Matches the
        // iOS ellipsis, which swaps the same item between the two
        // notifications based on `isViewingDay`.
        Button {
            NotificationCenter.default.post(
                name: isViewingDay ? .snorecardOpenDailyNotes : .snorecardOpenDeviceNotes,
                object: nil
            )
        } label: {
            Label("Sleep Journal", systemImage: "note.text")
        }
        .disabled(!hasCard)

        // Therapy Details is day-specific, so the menu entry is
        // always visible (menu-bar convention: advertise the
        // command, disable when inapplicable) but only enabled
        // while a day is selected.
        Button {
            NotificationCenter.default.post(name: .snorecardOpenDailySettings, object: nil)
        } label: {
            Label("Therapy Details", systemImage: "gauge.with.needle")
        }
        .disabled(!hasCard || !isViewingDay)

        if !otherDevices.isEmpty {
            Divider()
            Menu {
                ForEach(otherDevices) { folder in
                    Button(menuLabel(for: folder)) {
                        library.load(folder.url)
                    }
                }
            } label: {
                Label("Switch PAP Device", systemImage: "rectangle.2.swap")
            }
        }

        Divider()

        Button {
            NotificationCenter.default.post(name: .snorecardShowBackups, object: nil)
        } label: {
            Label("Backup & Restore", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
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
