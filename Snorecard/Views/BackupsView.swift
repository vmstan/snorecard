import SwiftUI
import SnorecardKit

/// Restore-from-backup sheet / inspector. Lists every archive in
/// iCloud's `Backups/` folder that matches the currently-loaded
/// device serial, newest first, with a restore and a delete
/// action per row. Also surfaces a "Back Up Now" button so the
/// user can stack up a fresh archive from the same surface.
struct BackupsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var backups: [Library.BackupFile] = []
    /// Which backup the user has asked to restore — drives the
    /// confirmation alert.
    @State private var restoreTarget: Library.BackupFile?
    /// Which backup the user has asked to delete — drives the
    /// delete confirmation.
    @State private var deleteTarget: Library.BackupFile?
    /// Set while a backup create / restore is in-flight so we can
    /// show progress and disable the other actions.
    @State private var busyMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Backup & Restore")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        CloseSheetButton { dismiss() }
                    }
                }
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .task { reloadList() }
        .alert(
            "Restore from Backup?",
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            ),
            presenting: restoreTarget
        ) { backup in
            Button("Cancel", role: .cancel) { }
            Button("Restore", role: .destructive) {
                runRestore(backup)
            }
        } message: { backup in
            Text("""
            This will replace the current data for this device with the contents of the backup from \(backup.createdAt, format: .dateTime.year().month().day().hour().minute()).

            The current version is moved aside during the swap and discarded once the restore completes successfully.
            """)
        }
        .alert(
            "Delete Backup?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { backup in
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                library.deleteBackup(backup)
                reloadList()
            }
        } message: { backup in
            Text("Permanently remove the archive from \(backup.createdAt, format: .dateTime.year().month().day().hour().minute()) from iCloud.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if backups.isEmpty && busyMessage == nil {
            ContentUnavailableView {
                Label("No Backups Yet", systemImage: "externaldrive.badge.plus")
            } description: {
                Text("Snapshots are stored in iCloud Drive under Snorecard → Backups and are accessible to every device signed in to this account.")
            } actions: {
                Button {
                    runBackup()
                } label: {
                    Label("Backup", systemImage: "square.and.arrow.down")
                }
                .disabled(library.card == nil)
            }
        } else {
            VStack(spacing: 0) {
                if let busyMessage {
                    busyChip(message: busyMessage)
                }
                List {
                    ForEach(backups) { backup in
                        row(for: backup)
                    }
                }
                #if os(macOS)
                .listStyle(.inset)
                #endif

                Text("Backups live in iCloud Drive → Snorecard → Backups and are accessible to every device signed in to this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    #if os(iOS)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    #else
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                // Persistent action footer. Back Up Now sits on
                // the leading edge; Done (macOS only — iOS gets a
                // drag indicator for dismissal) on the trailing
                // edge so both primary actions sit on the same
                // row instead of stacking vertically.
                HStack {
                    #if os(macOS)
                    // The Backup window has Spotlight-style
                    // traffic-light controls — the red close
                    // button handles dismiss, so Done is
                    // redundant. Backup sits on the trailing
                    // edge as the sole confirmation action.
                    Spacer()
                    Button("Backup") { runBackup() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(library.card == nil)
                    #else
                    // iOS styles Backup as a full-width, plain
                    // text button on a `secondarySystemGrouped`
                    // plate — matches the look of the "Use
                    // Default Name" Form Section button on the
                    // Rename Device sheet without needing to
                    // rebuild the whole panel as a Form.
                    Button {
                        runBackup()
                    } label: {
                        Text("Backup")
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 11)
                            .foregroundStyle(library.card == nil ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        // 12pt matches iOS's `.buttonStyle(.bordered)`
                        // and the bordered Restore button on each
                        // backup row, so the action surfaces in the
                        // sheet read as one consistent set.
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .disabled(library.card == nil)
                    #endif
                }
                #if os(macOS)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                #else
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                #endif
            }
        }
    }

    @ViewBuilder
    private func row(for backup: Library.BackupFile) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.body)
                HStack(spacing: 8) {
                    Text(formatBytes(backup.byteSize))
                    Text(backup.serial)
                        .monospaced()
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                restoreTarget = backup
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.bordered)
            .disabled(busyMessage != nil)

            // Direct trash button replaces the swipe-to-delete
            // gesture — stays put instead of shoving the Restore
            // button offscreen when interacted with. Still goes
            // through the `deleteTarget` alert for confirmation
            // so an accidental tap can't permanently remove the
            // archive.
            Button(role: .destructive) {
                deleteTarget = backup
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(busyMessage != nil)
            .help("Delete this backup")
        }
        .contextMenu {
            Button(role: .destructive) {
                deleteTarget = backup
            } label: {
                Label("Delete Backup", systemImage: "trash")
            }
        }
    }

    /// Inline progress chip that lives at the top of the list
    /// while a backup or restore is in flight. Stays out of the
    /// way of the existing rows so the user can see the
    /// new entry land the moment the chip disappears — that
    /// transition is the "done" signal.
    @ViewBuilder
    private func busyChip(message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            Text("Keep the app open")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Actions

    private func runBackup() {
        Task { @MainActor in
            withAnimation { busyMessage = "Creating backup…" }
            defer { withAnimation { busyMessage = nil } }
            do {
                _ = try await library.createBackup()
                reloadList()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func runRestore(_ backup: Library.BackupFile) {
        Task { @MainActor in
            withAnimation { busyMessage = "Restoring backup…" }
            defer { withAnimation { busyMessage = nil } }
            do {
                try await library.restoreBackup(backup)
                dismiss()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func reloadList() {
        let serial = library.card?.identification?.serialNumber
        backups = Library.listBackups(forSerial: serial)
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
