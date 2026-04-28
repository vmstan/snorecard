import SwiftUI
import SnorecardKit

/// Friendly full-pane loading screen used while the app reaches for
/// data — either downloading placeholders from iCloud, re-scanning a
/// device folder after an import, or opening the app for the first
/// time. Mirrors the empty / failed `ContentUnavailableView` layout
/// so the whole "loading pane" hierarchy feels cohesive.
struct LoadingView: View {
    let url: URL
    let prefetchProgress: CloudPrefetcher.Progress?
    let deviceName: String?

    private enum Phase {
        case downloading(completed: Int, total: Int)
        case scanning
    }

    private var phase: Phase {
        if let progress = prefetchProgress, progress.total > 0 {
            return .downloading(completed: progress.completed, total: progress.total)
        }
        return .scanning
    }

    private var iconName: String {
        switch phase {
        case .downloading: "icloud.and.arrow.down"
        case .scanning:    "moon.zzz"
        }
    }

    private var title: String {
        if let deviceName, !deviceName.isEmpty {
            return "Loading \(deviceName)"
        }
        return "Importing Sleep Data"
    }

    private var statusText: String {
        switch phase {
        case .downloading(let completed, let total):
            return "Syncing from iCloud — \(completed) of \(total)"
        case .scanning:
            return "Please leave the app open during this process…"
        }
    }

    var body: some View {
        // Matches the centering / padding of the `.empty` and
        // `.failed` states which also use ContentUnavailableView —
        // Apple's container lays out against the *visible* portion
        // of the pane (respecting the translucent toolbar) instead
        // of the raw geometry a manual VStack would measure.
        ContentUnavailableView {
            Label {
                Text(title)
                    .multilineTextAlignment(.center)
            } icon: {
                Image(systemName: iconName)
                    .symbolEffect(.pulse, options: .repeating)
            }
        } description: {
            Text(statusText)
                .multilineTextAlignment(.center)
        } actions: {
            if case .downloading(let completed, let total) = phase {
                ProgressView(
                    value: Double(completed),
                    total: Double(max(total, 1))
                )
                .progressViewStyle(.linear)
                .frame(maxWidth: 240)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .transition(.opacity)
    }
}
