import SwiftUI
import SnorecardKit

/// Reusable Form sections that list every archive in iCloud's
/// `Backups/` folder for the currently-loaded device (plus
/// busy/error banners, restore/delete actions, and an inline
/// "Back Up Now" button). Callers embed this inside their own
/// grouped `Form` — the sections own their own state + dialogs so
/// no backup plumbing has to flow through the caller.
struct BackupsFormSections: View {
    @Environment(Library.self) private var library

    /// Called after a successful restore. iOS pops the containing
    /// NavigationStack; macOS is a no-op because Backups lives
    /// inline in Settings.
    let onRestoreComplete: () -> Void

    @State private var backups: [Library.BackupFile] = []
    @State private var pendingConfirmation: PendingConfirmation?
    /// Set while a backup create / restore is in-flight so we can
    /// show progress and disable the other actions.
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    /// Transient success banner shown at the top of the section
    /// after a create / restore completes, so the user gets a
    /// visible "it worked" moment even though the list refresh
    /// already reflects the new archive. Cleared after a couple
    /// of seconds by `flashCompletion(_:)`.
    @State private var completionMessage: String?
    /// Flips to `true` once the initial `reloadList()` has run.
    /// Until then the Backups section renders a placeholder row
    /// instead of the empty-state text so the view body has the
    /// same shape on first layout as it does after backups load —
    /// that stability matters because the macOS inspector's
    /// collapse animation crashes if the hosted view's preference
    /// graph reshapes mid-animation.
    @State private var didLoad = false

    /// Sum type for the confirmation dialog so we only attach one
    /// `.confirmationDialog` modifier instead of three separate
    /// root-level `.alert`s. Fewer modifiers means fewer
    /// preferences flowing up to the window during the inspector
    /// animation on macOS.
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
        backupsSection
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
            // initial inspector open animation (macOS) completes
            // before `backups` changes and reshapes the view's
            // preference graph. Mutating synchronously in `.task`
            // / `.onAppear` was crashing inside
            // `_postWindowNeedsUpdateConstraints`.
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
            // Single always-present status row so iOS's List
            // treats the busy → completion swap as a content
            // update instead of a delete-then-insert; otherwise
            // the checkmark banner can flicker out before the
            // user sees it.
            if busyMessage != nil || completionMessage != nil {
                HStack(spacing: 10) {
                    if let busyMessage {
                        ProgressView()
                            .controlSize(.small)
                        Text(busyMessage)
                        Spacer()
                        Text("Keep the app open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let completionMessage {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(completionMessage)
                        Spacer()
                    }
                }
            }

            if !didLoad {
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

            Button("Backup Now") {
                runBackup()
            }
            .disabled(library.card == nil || busyMessage != nil)
        } header: {
            Text("Available Backups")
        } footer: {
            Text("Backups live in iCloud Drive → Snorecard → Backups and are accessible to every device signed in to this account.")
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
            let typeName = library.deviceType(for: library.card).displayName
            return """
            This will replace the current data for the \(typeName) with the contents of the backup from \(stamp).

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
                flashCompletion("Backup created")
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
                flashCompletion("Backup restored")
                onRestoreComplete()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func reloadList() {
        let serial = library.card?.identification?.serialNumber
        backups = Library.listBackups(forSerial: serial)
    }

    /// Show a success banner for a few seconds so the user gets
    /// visible confirmation that the create / restore finished —
    /// otherwise the progress spinner just disappears and the
    /// operation reads as silently aborted.
    private func flashCompletion(_ text: String) {
        withAnimation { completionMessage = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { completionMessage = nil }
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
