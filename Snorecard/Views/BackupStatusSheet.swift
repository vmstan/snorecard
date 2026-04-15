import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Modal sheet that reflects the current `Library.BackupState`.
/// Shows an indeterminate spinner while copying, a success view with a
/// "Show in Finder" button on completion, or an error card on failure.
struct BackupStatusSheet: View {
    let state: Library.BackupState
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            switch state {
            case .idle:
                EmptyView()

            case .running(let name):
                ProgressView()
                    .controlSize(.large)
                Text("Backing up SD card…")
                    .font(.headline)
                Text(name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("This can take a few minutes on a slow card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .completed(let url):
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.green)
                Text("Backup complete")
                    .font(.headline)
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    #if os(macOS)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    #endif
                    Button("Done") { onDismiss() }
                        .keyboardShortcut(.defaultAction)
                }

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.orange)
                Text("Backup failed")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Dismiss") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 360)
    }
}
