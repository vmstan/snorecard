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
        return "Loading your sleep data"
    }

    private var statusText: String {
        switch phase {
        case .downloading(let completed, let total):
            return "Syncing from iCloud — \(completed) of \(total)"
        case .scanning:
            return "Reading sleep data…"
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: iconName)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            if case .downloading(let completed, let total) = phase {
                ProgressView(
                    value: Double(completed),
                    total: Double(max(total, 1))
                )
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .transition(.opacity)
    }
}
