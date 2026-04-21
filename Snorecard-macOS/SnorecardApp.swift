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
    static let snorecardShowSettings = Notification.Name("Snorecard.ShowSettings")
    // Sleep Analysis and Rebuild Cache are declared in the
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
            CommandGroup(after: .toolbar) {
                viewCommands
            }
            CommandGroup(replacing: .appSettings) {
                Button {
                    NotificationCenter.default.post(name: .snorecardShowSettings, object: nil)
                } label: {
                    Label("Settings…", systemImage: "gearshape")
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

    /// File-menu command stack — Refresh, Import SD Card, and (when
    /// multiple devices are known) the Switch PAP Device submenu.
    /// Everything else that opens a pane or auxiliary window lives
    /// in the View menu via `viewCommands`.
    @ViewBuilder
    private var fileCommands: some View {
        let hasCard = library.card?.identification?.serialNumber != nil
        let currentSerial = library.card?.identification?.serialNumber
        let otherDevices = Library.iCloudDeviceFolders().filter { folder in
            folder.serial != currentSerial
        }

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
    }

    /// View-menu additions — all day- or scope-scoped panes and
    /// auxiliary windows. The entries advertise themselves even when
    /// disabled (standard menu-bar convention) so users can learn
    /// the commands exist before they have a card loaded.
    @ViewBuilder
    private var viewCommands: some View {
        let hasCard = library.card?.identification?.serialNumber != nil
        let isViewingDay: Bool = {
            if case .day = library.selection { return true }
            return false
        }()

        Divider()

        // Reload re-reads the currently-loaded card — a view-level
        // operation, not a file-level one. Lives at the top of the
        // View menu to match the Safari ⌘R "Reload Page" convention.
        Button {
            library.reloadCurrent()
        } label: {
            Label("Reload Data", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(!hasCard)

        Divider()

        // Sleep Analysis covers both scopes: per-night on the day
        // view, per-range on Trends. Posts whichever notification
        // matches the current selection, mirroring how Sleep Journal
        // swaps between daily / device notes.
        Button {
            NotificationCenter.default.post(
                name: isViewingDay ? .snorecardOpenSleepAnalysis : .snorecardOpenTrendsAnalysis,
                object: nil
            )
        } label: {
            Label("Sleep Analysis", systemImage: "sparkles")
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .disabled(!hasCard || !library.intelligence.isReady)

        Button {
            NotificationCenter.default.post(
                name: isViewingDay ? .snorecardOpenDailyNotes : .snorecardOpenDeviceNotes,
                object: nil
            )
        } label: {
            Label("Sleep Journal", systemImage: "note.text")
        }
        .keyboardShortcut("j", modifiers: [.command, .shift])
        .disabled(!hasCard)

        Button {
            NotificationCenter.default.post(name: .snorecardOpenDailySettings, object: nil)
        } label: {
            Label("Therapy Details", systemImage: "gauge.with.needle")
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!hasCard || !isViewingDay)

        Divider()

        // Detailed Statistics + Advanced Charting route through
        // DayDetailView (which holds the loaded waveform bundle and
        // file URLs) so the payload can be constructed with the
        // current day's data before `openWindow(value:)` is called.
        Button {
            NotificationCenter.default.post(name: .snorecardOpenDetailedStatistics, object: nil)
        } label: {
            Label("Detailed Statistics", systemImage: "tablecells")
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(!hasCard || !isViewingDay)

        Button {
            NotificationCenter.default.post(name: .snorecardOpenAdvancedCharting, object: nil)
        } label: {
            Label("Advanced Charting", systemImage: "waveform.path.ecg")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(!hasCard || !isViewingDay)

        Divider()
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
