import SwiftUI
import SnorecardKit

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var isRenamingDevice = false

    var body: some View {
        @Bindable var library = library

        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                #if os(iOS)
                .toolbar { toolbarButtons }
                #endif
        } detail: {
            detail
        }
        #if os(macOS)
        .toolbar { toolbarButtons }
        #endif
        .sheet(isPresented: $isRenamingDevice) {
            if let card = library.card,
               let serial = card.identification?.serialNumber {
                RenameDeviceSheet(
                    serial: serial,
                    defaultName: card.identification?.productName ?? "ResMed Device",
                    currentOverride: library.deviceNameOverrides[serial],
                    onSave: { newName in
                        library.setDeviceName(newName, for: serial)
                    }
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    openSDCard()
                } label: {
                    Label("Import from SD Card", systemImage: "sdcard")
                }
                #if os(macOS)
                .keyboardShortcut("o", modifiers: [.command])
                #endif

                if let card = library.card,
                   card.identification?.serialNumber != nil {
                    Divider()
                    Button {
                        isRenamingDevice = true
                    } label: {
                        Label("Rename Device…", systemImage: "square.and.pencil")
                    }
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            #if os(macOS)
            .help("Import data or rename the current device")
            #endif
        }
    }

    // MARK: - Actions

    private func openSDCard() {
        #if os(macOS)
        if let url = presentFolderPicker(
            prompt: "Open",
            message: "Select a ResMed SD card or DATALOG export folder"
        ) {
            library.load(url)
        }
        #else
        presentIOSFolderPicker { url in
            library.load(url)
        }
        #endif
    }

    @ViewBuilder
    private var sidebar: some View {
        @Bindable var library = library

        Group {
            switch library.state {
            case .empty:
                ContentUnavailableView {
                    Label("No SD Card", systemImage: "externaldrive")
                } description: {
                    Text("Import a ResMed SD card folder to begin.")
                } actions: {
                    Button {
                        openSDCard()
                    } label: {
                        Label("Import from SD Card", systemImage: "sdcard")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .loading(let url):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning \(url.lastPathComponent)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        openSDCard()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .loaded(let card):
                DayListView(card: card, selection: $library.selection)
            }
        }
        .navigationTitle("Snorecard")
    }

    @ViewBuilder
    private var detail: some View {
        if case .loaded(let card) = library.state {
            switch library.selection {
            case .overview:
                OverviewView(card: card)
            case .day:
                if let day = library.selectedDay {
                    DayDetailView(day: day)
                } else {
                    ContentUnavailableView(
                        "Day not found",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                }
            case .none:
                ContentUnavailableView(
                    "Select Overview or a day",
                    systemImage: "sidebar.left",
                    description: Text("Pick something from the sidebar.")
                )
            }
        } else {
            Color.clear
        }
    }
}
