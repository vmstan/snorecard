import SwiftUI

/// Shared title + caption block used at the top of every
/// inspector pane / sheet — Sleep Analysis, Sleep Journal,
/// Therapy Details, Rename Device, Backup & Restore.
///
/// Big primary title reads as the pane's context (the date
/// for per-night panes, the device name for device-wide
/// panes), small secondary caption describes what the pane
/// contains. Keeps the whole inspector column visually
/// consistent and free of the sparkles / capsule
/// badge dance the AI cards experimented with earlier.
struct InspectorPaneHeader<Title: View>: View {
    let title: Title
    let caption: String

    init(@ViewBuilder title: () -> Title, caption: String) {
        self.title = title()
        self.caption = caption
    }

    init(title: String, caption: String) where Title == Text {
        self.title = Text(title)
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.title2.weight(.semibold))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
