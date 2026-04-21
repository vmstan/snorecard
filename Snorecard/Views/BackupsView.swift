import SwiftUI
import SnorecardKit

/// Restore-from-backup inspector / sheet. Lists every archive in
/// iCloud's `Backups/` folder that matches the currently-loaded
/// device serial, newest first, with a restore and a delete
/// action per row, plus a "Back Up Now" action in the footer bar.
///
/// The macOS layout mirrors `RenameDeviceSheet` and
/// `DailySettingsInspector` on purpose: a grouped `Form` for the
/// content, a bottom action bar pulled in via `.safeAreaInset`,
/// and no `.alert` or `.task` modifiers on the root. The shared
/// third-column inspector crashes during its collapse/expand
/// animation if the hosted view mutates state or vends toolbar
/// preferences while the split view is still animating, so the
/// structure here avoids both: the backup list is loaded from a
/// `DispatchQueue.main.async` hop inside `.onAppear` (pushing the
/// state update to the next runloop pass, after layout settles)
/// and destructive confirmations use a single consolidated
/// confirmation dialog attached inside the Form rather than three
/// root-level alerts.
struct BackupsView: View {
    @Environment(Library.self) private var library
    /// Explicit close callback. `@Environment(\.dismiss)` would
    /// target the host window when this view is hosted inside
    /// the macOS inspector, which would quit the app instead of
    /// collapsing the inspector column.
    let onClose: () -> Void

    @State private var backups: [Library.BackupFile] = []
    @State private var pendingConfirmation: PendingConfirmation?
    /// Set while a backup create / restore is in-flight so we can
    /// show progress and disable the other actions.
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    /// Flips to `true` once the initial `reloadList()` has run.
    /// Until then the Backups section renders a placeholder row
    /// instead of the empty-state text so the view body has the
    /// same shape on first layout as it does after backups load —
    /// that stability matters because the inspector's collapse
    /// animation crashes if the hosted view's preference graph
    /// reshapes mid-animation.
    @State private var didLoad = false

    /// Sum type for the confirmation dialog so we only attach one
    /// `.confirmationDialog` modifier to the Form instead of three
    /// separate root-level `.alert`s. Fewer modifiers means fewer
    /// preferences flowing up to the window during the inspector
    /// animation.
    private enum PendingConfirmation: Identifiable {
        case restore(Library.BackupFile)
        case delete(Library.BackupFile)

        var id: String {
            switch self {
            case .restore(let b): return "restore-\(b.id)"
            case .delete(let b): return "delete-\(b.id)"
            }
        }
    }

    var body: some View {
        #if os(iOS)
        // `InspectorPaneHeader` inside `formBody` supplies the
        // pane title, so iOS skips `.navigationTitle` to avoid
        // stacking a duplicate in the top bar.
        NavigationStack {
            formBody
                .padding(.top, 12)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Backup") { runBackup() }
                            .disabled(library.card == nil || busyMessage != nil)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        // macOS hosts this in the shared inspector column. No
        // `NavigationStack` wrapper — its toolbar bridge conflicts
        // with the root `NavigationSplitView`'s toolbar during the
        // inspector collapse/expand animation. Matches the plain
        // `.navigationTitle` pattern `RenameDeviceSheet` and
        // `DailySettingsInspector` already use in the same column.
        formBody
            .navigationTitle("Backup & Restore")
        #endif
    }

    // MARK: - Form body

    @ViewBuilder
    private var formBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorPaneHeader(
                title: deviceHeaderTitle,
                caption: "Archived PAP-device data stored in iCloud Drive"
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            form
        }
    }

    @ViewBuilder
    private var form: some View {
        Form {
            if let busyMessage {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(busyMessage)
                        Spacer()
                        Text("Keep the app open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            backupsSection

            Section {
                EmptyView()
            } footer: {
                Text("Backups live in iCloud Drive → Snorecard → Backups and are accessible to every device signed in to this account.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationBinding,
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { pending in
            confirmationButtons(for: pending)
        } message: { pending in
            Text(confirmationMessage(for: pending))
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
        .onAppear {
            // Defer the state mutation by one runloop pass so the
            // initial inspector open animation (which drives the
            // `NSSplitViewItem setCollapsed:` → toolbar-bridge
            // update path) completes before `backups` changes and
            // reshapes the view's preference graph. Mutating
            // synchronously in `.task` / `.onAppear` was crashing
            // inside `_postWindowNeedsUpdateConstraints`.
            DispatchQueue.main.async {
                reloadList()
                didLoad = true
            }
        }
    }

    // MARK: - Backups section

    @ViewBuilder
    private var backupsSection: some View {
        Section {
            if !didLoad {
                // Placeholder row — keeps the Section non-empty on
                // the very first layout so the Form's preference
                // graph doesn't reshape when the real rows arrive
                // on the next runloop pass.
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading backups…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if backups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No Backups Yet", systemImage: "externaldrive.badge.plus")
                        .font(.body)
                    Text("Snapshots are stored in iCloud Drive under Snorecard → Backups and are accessible to every device signed in to this account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(backups) { backup in
                    row(for: backup)
                }
            }
        } header: {
            Text("Available Backups")
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
                pendingConfirmation = .restore(backup)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(busyMessage != nil)
            .help("Restore this backup")

            Button(role: .destructive) {
                pendingConfirmation = .delete(backup)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .disabled(busyMessage != nil)
            .help("Delete this backup")
        }
        .contextMenu {
            Button(role: .destructive) {
                pendingConfirmation = .delete(backup)
            } label: {
                Label("Delete Backup", systemImage: "trash")
            }
        }
    }

    /// Label used in the big header above the Form. Prefers the
    /// user-set alias, falls back to the ResMed product name, and
    /// lands on a generic device label so the pane never looks
    /// orphaned when nothing is loaded yet.
    private var deviceHeaderTitle: String {
        if let card = library.card {
            return library.displayName(for: card)
        }
        return "Backups"
    }

    // MARK: - Action bar

    @ViewBuilder
    private var actionBar: some View {
        #if os(macOS)
        // macOS bar mirrors `RenameDeviceSheet` — close button on
        // the leading edge routes through `onClose` (not
        // `dismiss()`, which would target the host window), and
        // Backup on the trailing edge is the default-action
        // confirmation button.
        HStack {
            Button("Cancel") { onClose() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Backup") { runBackup() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(library.card == nil || busyMessage != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.bar)
        #else
        // iOS routes the Backup action through the navigation bar
        // trailing item, so the bottom inset is empty.
        EmptyView()
        #endif
    }

    // MARK: - Confirmation dialog plumbing

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .restore: return "Restore from Backup?"
        case .delete:  return "Delete Backup?"
        case .none:    return ""
        }
    }

    private func confirmationMessage(for pending: PendingConfirmation) -> String {
        switch pending {
        case .restore(let backup):
            let stamp = backup.createdAt.formatted(.dateTime.year().month().day().hour().minute())
            return """
            This will replace the current data for the PAP-device with the contents of the backup from \(stamp).

            The current version is moved aside during the swap and discarded once the restore completes successfully.
            """
        case .delete(let backup):
            let stamp = backup.createdAt.formatted(.dateTime.year().month().day().hour().minute())
            return "Permanently remove the archive from \(stamp) from iCloud."
        }
    }

    @ViewBuilder
    private func confirmationButtons(for pending: PendingConfirmation) -> some View {
        switch pending {
        case .restore(let backup):
            Button("Restore", role: .destructive) {
                runRestore(backup)
            }
            Button("Cancel", role: .cancel) { }
        case .delete(let backup):
            Button("Delete", role: .destructive) {
                library.deleteBackup(backup)
                reloadList()
            }
            Button("Cancel", role: .cancel) { }
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
                onClose()
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
