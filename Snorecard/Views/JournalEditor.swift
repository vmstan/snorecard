import SwiftUI

/// Shared writing surface used by `NotesCard` (per-night) and
/// `DeviceNotesCard` (device-wide). A multi-line `TextField` with a
/// vertical growth axis renders its own placeholder in the field's
/// exact font and position, so we don't have to overlay a `Text`
/// that can drift from the cursor position. The field is wrapped
/// in a `ScrollView` so the shaded background fills the pane and
/// content taller than the pane scrolls instead of being clipped.
struct JournalEditor: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        ScrollView {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .padding(.horizontal, -4)
    }
}
