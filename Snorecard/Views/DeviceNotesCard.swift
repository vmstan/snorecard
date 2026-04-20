import SwiftUI
import SnorecardKit

/// Free-form device-wide journal entry, rendered in the shared
/// inspector when the Overview is selected. Mirrors `NotesCard`
/// (same debounced autosave, same blank-means-delete rule) but
/// talks to the device-level sidecar rather than a per-night one,
/// so the user can keep overall notes about a CPAP — mask changes,
/// pressure tweaks, travel context — that aren't tied to a
/// specific night.
struct DeviceNotesCard: View {
    @Environment(Library.self) private var library

    @State private var text: String = ""
    /// Tracks the last value we actually wrote to disk so we can
    /// short-circuit redundant saves.
    @State private var savedText: String = ""
    /// Cancelled and rescheduled on every keystroke — when it
    /// completes, the current text is written out.
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                InspectorPaneHeader(
                    title: "Sleep Journal",
                    caption: deviceHeader
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
                    .help("Clear the device-wide journal entry")
                }
            }

            #if os(macOS)
            Text("Press ⌥ + ↩ for a new line")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif

            TextField(
                "Overall notes for this PAP-device — mask changes, pressure tweaks, anything not tied to a single night…",
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(6, reservesSpace: true)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .task(id: deviceSerial) {
            // When the selected device changes, flush any pending
            // save for the previous device and load the new one's
            // note. Keyed on serial so switching devices from the
            // sidebar swaps the entry cleanly.
            saveTask?.cancel()
            let loaded = library.deviceNote()?.text ?? ""
            text = loaded
            savedText = loaded
        }
        .onChange(of: text) { _, newValue in
            scheduleAutosave(newValue: newValue)
        }
        .onDisappear {
            saveTask?.cancel()
            flushIfChanged(text)
        }
    }

    /// Device identity line above the editor. Prefers the user-set
    /// alias, falls back to the product name, and lands on a
    /// generic "This Device" label so the card never looks orphaned.
    private var deviceHeader: String {
        if let card = library.card {
            if let serial = card.identification?.serialNumber,
               let override = library.deviceNameOverrides[serial],
               !override.isEmpty {
                return override
            }
            if let product = card.identification?.productName, !product.isEmpty {
                return product
            }
        }
        return "This PAP-device"
    }

    private var deviceSerial: String {
        library.card?.identification?.serialNumber ?? ""
    }

    private func scheduleAutosave(newValue: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            flushIfChanged(newValue)
        }
    }

    private func flushIfChanged(_ value: String) {
        guard value != savedText else { return }
        library.setDeviceNote(value)
        savedText = value
    }
}
