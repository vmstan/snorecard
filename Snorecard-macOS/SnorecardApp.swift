import SwiftUI
import AppKit

@main
struct SnorecardApp: App {
    @State private var library = Library()

    /// Disable AppKit's automatic window tabbing. SwiftUI doesn't
    /// expose `NSWindow.tabbingMode`, so without this the View menu
    /// shows Show Tab Bar / Merge All Windows / tab-cycling
    /// shortcuts that do nothing useful — every one of our windows
    /// is a distinct scene (Main, Settings, Detailed Statistics,
    /// Advanced Charting, About) keyed on its own payload, so
    /// grouping them as tabs has no meaningful UX. Runs in `init`
    /// so the flag is set before any `NSWindow` is created.
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

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
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }
            CommandGroup(replacing: .newItem) {
                fileCommands
            }
            CommandGroup(after: .toolbar) {
                viewCommands
            }
        }

        // Standard macOS preferences window — SwiftUI wires the
        // Snorecard ▸ Settings… menu item (⌘,) to this scene
        // automatically, matching every other Mac app instead of
        // opening an in-window inspector pane.
        Settings {
            SettingsWindowHost()
                .environment(library)
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
                    .environment(library)
                    .frame(minWidth: 960, minHeight: 640)
            }
        }

        // Standalone About window opened from the overridden
        // Snorecard ▸ About Snorecard menu item. `Window` (vs
        // `WindowGroup`) is a singleton, so repeat triggers bring
        // the existing window forward instead of stacking copies.
        Window("About Snorecard", id: "about") {
            AboutView()
                .frame(width: 420, height: 620)
        }
        .windowResizability(.contentSize)
    }

    /// `CommandGroup(replacing: .appInfo)` body — routes the default
    /// Snorecard ▸ About Snorecard menu item to our SwiftUI About
    /// window via `openWindow(id:)` instead of the AppKit-supplied
    /// standard About panel.
    private struct AboutMenuItem: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button {
                openWindow(id: "about")
            } label: {
                Label("About Snorecard", systemImage: "info.circle")
            }
        }
    }

    /// File-menu command stack — Refresh, Import SD Card, and (when
    /// multiple devices are known) the Switch PAP Device submenu.
    /// Everything else that opens a pane or auxiliary window lives
    /// in the View menu via `viewCommands`.
    @ViewBuilder
    private var fileCommands: some View {
        let currentSerial = library.card?.identification?.serialNumber
        let otherDevices = Library.iCloudDeviceFolders().filter { folder in
            folder.serial != currentSerial
        }

        Button {
            NotificationCenter.default.post(name: .snorecardImportSDCard, object: nil)
        } label: {
            Label("Import Sleep Data", systemImage: "externaldrive.badge.plus")
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
                Label("Swap Machines", systemImage: "rectangle.2.swap")
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
            NotificationCenter.default.post(name: .snorecardOpenSessions, object: nil)
        } label: {
            Label("Therapy Sessions", systemImage: "clock")
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(!hasCard || !isViewingDay)

        Button {
            NotificationCenter.default.post(name: .snorecardOpenDailySettings, object: nil)
        } label: {
            Label("Therapy Details", systemImage: "fan")
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
            Label("Detailed Waveforms", systemImage: "waveform")
        }
        .keyboardShortcut("w", modifiers: [.command, .shift])
        .disabled(!hasCard || !isViewingDay)

        Divider()
    }

    /// Wrapper around `SettingsSheet` that gives its `onClose`
    /// callback somewhere real to go — destructive actions like
    /// Rebuild Cache need to close the Settings window first so
    /// the confirmation alert in the main window isn't hidden
    /// behind it.
    private struct SettingsWindowHost: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            SettingsSheet(onClose: { dismiss() })
                .frame(width: 560, height: 560)
        }
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
        return "Machine \(folder.serial)"
    }
}
