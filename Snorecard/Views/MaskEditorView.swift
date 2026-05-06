import SwiftUI
import SnorecardKit

/// Add / edit screen for a single `Mask` record. The presentation
/// shape diverges per platform because the surrounding chrome does:
///
/// - iOS pushes this view onto the outer Settings `NavigationStack`,
///   so a toolbar `Save` button and the standard back-chevron carry
///   the user through. Edits also commit on disappear so a swipe-back
///   doesn't lose work.
/// - macOS presents this view inside a sheet (Settings tabs can't
///   push reliably without leaving the user stuck — the sheet gives
///   them a clear way out). Explicit `Cancel` and `Save` buttons sit
///   in a footer row, and there is no commit-on-disappear so Cancel
///   actually cancels.
struct MaskEditorView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// Original mask we're editing. `nil` when adding — the editor
    /// renders the same form but the Save action calls
    /// `Library.addMask` instead of `updateMask`, and the Delete
    /// row stays hidden.
    let initialMask: Mask?

    @State private var manufacturer: MaskManufacturer = .resmed
    @State private var customManufacturer: String = ""
    @State private var model: String = ""
    @State private var type: MaskType = .nasal
    @State private var size: MaskSize = .m

    @State private var didCommit = false
    @State private var showDeleteConfirmation = false

    private var isEditing: Bool { initialMask != nil }

    private var trimmedCustomManufacturer: String {
        customManufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Mask" : "Add Mask")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            Form { detailsSection }
                .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                if isEditing {
                    Button("Delete", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    didCommit = true
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    commitIfNeeded()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear(perform: hydrateDrafts)
        .confirmationDialog(
            "Delete this mask?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Mask", role: .destructive, action: deleteMask)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions already labeled with this mask keep their assignment until you change them.")
        }
    }
    #endif

    #if os(iOS)
    @ViewBuilder
    private var iosBody: some View {
        Form {
            detailsSection
            if isEditing {
                deleteSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isEditing ? "Edit Mask" : "Add Mask")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    commitIfNeeded()
                    dismiss()
                }
            }
        }
        .onAppear(perform: hydrateDrafts)
        .onDisappear(perform: commitIfNeeded)
        .confirmationDialog(
            "Delete this mask?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Mask", role: .destructive, action: deleteMask)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions already labeled with this mask keep their assignment until you change them.")
        }
    }
    #endif

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            Picker("Manufacturer", selection: $manufacturer) {
                ForEach(MaskManufacturer.allCases) { mfr in
                    Text(mfr.displayName).tag(mfr)
                }
            }
            if manufacturer == .other {
                LabeledContent("Custom") {
                    TextField(
                        "",
                        text: $customManufacturer,
                        prompt: Text("Brand")
                    )
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    #endif
                }
            }
            LabeledContent("Model") {
                TextField(
                    "",
                    text: $model,
                    prompt: Text("e.g. AirFit P30i")
                )
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                #endif
            }
            Picker("Type", selection: $type) {
                ForEach(MaskType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            Picker("Size", selection: $size) {
                ForEach(MaskSize.allCases) { size in
                    Text(size.displayName).tag(size)
                }
            }
        } footer: {
            Text("Pick \"Other\" and fill in the brand if your manufacturer isn't listed.")
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var deleteSection: some View {
        Section {
            Button("Delete Mask", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
    }
    #endif

    private func hydrateDrafts() {
        guard let initialMask else { return }
        manufacturer = initialMask.manufacturer
        customManufacturer = initialMask.customManufacturer ?? ""
        model = initialMask.model
        type = initialMask.type
        size = initialMask.size
    }

    private func commitIfNeeded() {
        guard !didCommit else { return }
        didCommit = true
        let custom = manufacturer == .other && !trimmedCustomManufacturer.isEmpty
            ? trimmedCustomManufacturer
            : nil
        if let initialMask {
            let updated = Mask(
                id: initialMask.id,
                manufacturer: manufacturer,
                customManufacturer: custom,
                model: trimmedModel,
                type: type,
                size: size
            )
            guard updated != initialMask else { return }
            library.updateMask(updated)
        } else {
            let new = Mask(
                manufacturer: manufacturer,
                customManufacturer: custom,
                model: trimmedModel,
                type: type,
                size: size
            )
            library.addMask(new)
        }
    }

    private func deleteMask() {
        guard let initialMask else { return }
        // Mark committed so the iOS onDisappear hook doesn't try to
        // round-trip an updateMask call against an id we just removed.
        didCommit = true
        library.deleteMask(id: initialMask.id)
        dismiss()
    }
}
