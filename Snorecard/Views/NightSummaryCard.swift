import SwiftUI
import SnorecardKit

/// On-device narrative of a single night's therapy data. Presented
/// as the macOS `.sleepAnalysis` inspector pane and as the iOS
/// Sleep Analysis sheet — accessed via the toolbar ellipsis /
/// File menu so the Day detail view isn't cluttered by an
/// auto-loading AI surface. Apple-Intelligence availability is
/// checked by the caller; this view assumes it can call
/// `library.nightSummary` and should render something meaningful
/// in every state (loading, loaded, failed).
struct NightSummaryCard: View {
    let day: ResMedDay
    @Environment(Library.self) private var library
    @State private var summary: NightSummaryOutput?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorPaneHeader(
                title: {
                    Text(day.date, format: .dateTime.weekday(.wide).day().month(.wide))
                },
                caption: "On-device analysis of this night"
            )
            Group {
                if let summary {
                    loadedContent(summary)
                } else if failed {
                    failedContent
                } else {
                    placeholderContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            Text("Summary only — not medical advice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: day.id) {
            await load()
        }
    }

    @ViewBuilder
    private func loadedContent(_ summary: NightSummaryOutput) -> some View {
        Text(summary.paragraph)
            .font(.callout)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeholderContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            Text("Writing a summary…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A summary isn't available right now.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await load() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func load() async {
        summary = nil
        failed = false
        let result = await library.nightSummary(for: day)
        if result == nil {
            failed = true
        } else {
            summary = result
        }
    }
}
