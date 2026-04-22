import SwiftUI
import SnorecardKit

/// Free-form per-night journal entry, rendered at the top of the
/// daily view. Always-editable `TextEditor` with a ~750 ms debounce
/// on autosave so typing doesn't churn iCloud on every keystroke.
/// Empty content deletes the sidecar so blank notes don't clutter
/// up the DATALOG tree.
struct NotesCard: View {
    let day: ResMedDay
    @Environment(Library.self) private var library

    @State private var text: String = ""
    /// Tracks the last value we actually wrote to disk so we can
    /// short-circuit redundant saves (e.g. view re-appearance with
    /// no edits) and know what to flush on disappear.
    @State private var savedText: String = ""
    /// Cancelled and rescheduled on every keystroke — when it
    /// completes, the current text is written out.
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                InspectorPaneHeader(
                    title: "Sleep Journal",
                    caption: dateCaption
                )
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Label("Clear", systemImage: "eraser")
                            .labelStyle(.iconOnly)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear this night's journal entry")
                }
            }

            JournalEditor(
                placeholder: "How did you sleep? Add any context about last night…",
                text: $text
            )
        }
        .task(id: day.id) {
            // When the viewed day changes, flush any pending save
            // for the previous day and load the new one's note.
            saveTask?.cancel()
            let loaded = library.note(for: day)?.text ?? ""
            text = loaded
            savedText = loaded
        }
        .onChange(of: text) { _, newValue in
            scheduleAutosave(newValue: newValue)
        }
        .onDisappear {
            // Force an immediate save on navigation away so the
            // user never loses the last few characters they typed
            // within the debounce window.
            saveTask?.cancel()
            flushIfChanged(text)
        }
    }

    /// Date caption below the "Sleep Journal" title — same
    /// formatting used everywhere else in the inspector set.
    private var dateCaption: String {
        day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }


    /// Cancel any queued autosave and schedule a fresh one for 750 ms
    /// from now. The task writes through to `Library.setNote` which
    /// persists to the sidecar.
    private func scheduleAutosave(newValue: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            flushIfChanged(newValue)
        }
    }

    /// Commit `value` to disk when it differs from what we last
    /// wrote. Centralised so both the debounce path and the
    /// navigate-away path share the same "skip no-op writes" rule.
    private func flushIfChanged(_ value: String) {
        guard value != savedText else { return }
        library.setNote(value, for: day)
        savedText = value
    }
}
