import SwiftUI
import SnorecardKit

/// First Settings tab — gathers the user's own details rather
/// than the machine's. Two sections:
///
/// 1. **Personal** — name, height, weight. Height + weight can
///    be filled from Apple Health on iOS; when imported, the
///    field is read-only and labelled with a "Sourced from
///    Apple Health" note plus a deep-link to the Health app.
///    Switching back to manual is a single tap.
/// 2. **Diagnosis** — untreated AHI from the user's diagnostic
///    sleep study and the diagnosis date.
///
/// All fields persist to iCloud KVS via `Library.setProfile`,
/// so changes ride iCloud to the user's other devices the same
/// way device-name overrides and compliance targets already do.
struct ProfileTab: View {
    @Environment(Library.self) private var library

    var body: some View {
        Form {
            personalSection
            diagnosisSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Personal

    @ViewBuilder
    private var personalSection: some View {
        Section {
            // Name — always manual, since HealthKit doesn't
            // surface the Medical-ID name to third-party apps.
            LabeledContent("Name") {
                TextField(
                    "",
                    text: nameBinding,
                    prompt: Text("Your name")
                )
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
            }

            sexRow
            dateOfBirthRow
            heightRow
            weightRow

            #if os(iOS)
            Button {
                Task { await library.importProfileFromHealthKit() }
            } label: {
                Label("Import from Apple Health", systemImage: "heart.text.square")
            }
            #endif
        } header: {
            Text("Personal")
        } footer: {
            // The footer carries the platform-specific "where to
            // edit Health-sourced fields" hint so users on iOS
            // know the Health app is the source of truth, and
            // macOS users know the field can be re-typed locally
            // or unlocked from the iPhone.
            Text(personalFooter)
        }
    }

    private var personalFooter: String {
        let imported = library.userProfile.heightSource == .healthKit
            || library.userProfile.weightSource == .healthKit
            || library.userProfile.biologicalSexSource == .healthKit
            || library.userProfile.dateOfBirthSource == .healthKit
        if imported {
            #if os(iOS)
            return "Height and weight imported from Apple Health appear as locked fields. Edit them in the Health app to keep both apps in sync."
            #else
            return "Height and weight imported from Apple Health on your iPhone are read-only here. Edit them in the Health app on your iPhone, or unlock the field below to override locally."
            #endif
        }
        #if os(iOS)
        return "Tap Import from Apple Health to fill height and weight from the Health app. Imported fields stay in sync with Health and become read-only here."
        #else
        return "Profile fields sync via iCloud. To pull height and weight from Apple Health, run the import on your iPhone."
        #endif
    }

    private var sexRow: some View {
        profileRow(
            label: "Sex",
            source: library.userProfile.biologicalSexSource,
            placeholder: "—",
            displayValue: library.userProfile.biologicalSex?.displayName,
            onUnlock: {
                var p = library.userProfile
                p.biologicalSexSource = .manual
                library.setProfile(p)
            },
            manualField: {
                Picker(
                    "",
                    selection: biologicalSexBinding
                ) {
                    Text("—").tag(BiologicalSex?.none)
                    ForEach(BiologicalSex.allCases) { sex in
                        Text(sex.displayName).tag(BiologicalSex?.some(sex))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        )
    }

    private var dateOfBirthRow: some View {
        profileRow(
            label: "Date of Birth",
            source: library.userProfile.dateOfBirthSource,
            placeholder: "—",
            displayValue: library.userProfile.dateOfBirth.map(Self.formatDateOfBirth),
            onUnlock: {
                var p = library.userProfile
                p.dateOfBirthSource = .manual
                library.setProfile(p)
            },
            manualField: {
                // The DatePicker carries its own label so the row
                // shows "Date of Birth" on the leading side and the
                // picker's compact field on the trailing side. The
                // outer `LabeledContent("Date of Birth")` renders the
                // leading label on macOS; the picker's own label is
                // hidden so the row doesn't read it twice.
                DatePicker(
                    "",
                    selection: dateOfBirthBinding,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .labelsHidden()
            }
        )
    }

    private var heightRow: some View {
        profileRow(
            label: "Height",
            source: library.userProfile.heightSource,
            placeholder: "—",
            displayValue: library.userProfile.heightCm.map(Self.formatHeight),
            onUnlock: {
                var p = library.userProfile
                p.heightSource = .manual
                library.setProfile(p)
            },
            manualField: {
                TextField(
                    "",
                    value: heightBinding,
                    format: .number.precision(.fractionLength(0...1)),
                    prompt: Text("cm")
                )
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            }
        )
    }

    private var weightRow: some View {
        profileRow(
            label: "Weight",
            source: library.userProfile.weightSource,
            placeholder: "—",
            displayValue: library.userProfile.weightKg.map(Self.formatWeight),
            onUnlock: {
                var p = library.userProfile
                p.weightSource = .manual
                library.setProfile(p)
            },
            manualField: {
                TextField(
                    "",
                    value: weightBinding,
                    format: .number.precision(.fractionLength(0...1)),
                    prompt: Text("kg")
                )
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            }
        )
    }

    /// Renders one Personal-section row in either editable or
    /// locked-from-Health form. The locked variant carries a
    /// small "Edit in Health" link on iOS (deep-link into the
    /// Health app) and an Unlock button so the user can switch
    /// the field back to manual without leaving Settings.
    @ViewBuilder
    private func profileRow<Field: View>(
        label: String,
        source: ProfileFieldSource,
        placeholder: String,
        displayValue: String?,
        onUnlock: @escaping () -> Void,
        @ViewBuilder manualField: () -> Field
    ) -> some View {
        switch source {
        case .manual:
            LabeledContent(label) { manualField() }
        case .healthKit:
            LabeledContent {
                HStack(spacing: 8) {
                    Text(displayValue ?? placeholder)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "heart.text.square")
                        .foregroundStyle(.pink)
                        .accessibilityLabel("From Apple Health")
                    Menu {
                        #if os(iOS)
                        if let url = URL(string: "x-apple-health://") {
                            Link(destination: url) {
                                Label("Edit in Health", systemImage: "heart")
                            }
                        }
                        #endif
                        Button("Unlock and Edit Manually", action: onUnlock)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                }
            } label: {
                Text(label)
            }
        }
    }

    // MARK: - Diagnosis

    @ViewBuilder
    private var diagnosisSection: some View {
        Section {
            LabeledContent("Untreated AHI") {
                TextField(
                    "",
                    value: untreatedAHIBinding,
                    format: .number.precision(.fractionLength(0...2)),
                    prompt: Text("events / hour")
                )
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            }
            DatePicker(
                "Diagnosed",
                selection: diagnosisDateBinding,
                displayedComponents: .date
            )
            if library.userProfile.diagnosisDate != nil {
                Button(role: .destructive) {
                    var p = library.userProfile
                    p.diagnosisDate = nil
                    library.setProfile(p)
                } label: {
                    Text("Clear Diagnosis Date")
                }
            }
        } header: {
            Text("Diagnosis")
        } footer: {
            Text("From your diagnostic sleep study, before therapy began. Useful as a long-running anchor for how far therapy has moved your AHI.")
        }
    }

    // MARK: - Bindings

    private var profile: UserProfile { library.userProfile }

    private var nameBinding: Binding<String> {
        Binding(
            get: { profile.name ?? "" },
            set: { value in
                var p = profile
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                p.name = trimmed.isEmpty ? nil : value
                library.setProfile(p)
            }
        )
    }

    private var heightBinding: Binding<Double?> {
        Binding(
            get: { profile.heightCm },
            set: { value in
                var p = profile
                p.heightCm = value
                p.heightSource = .manual
                library.setProfile(p)
            }
        )
    }

    private var weightBinding: Binding<Double?> {
        Binding(
            get: { profile.weightKg },
            set: { value in
                var p = profile
                p.weightKg = value
                p.weightSource = .manual
                library.setProfile(p)
            }
        )
    }

    private var untreatedAHIBinding: Binding<Double?> {
        Binding(
            get: { profile.untreatedAHI },
            set: { value in
                var p = profile
                p.untreatedAHI = value
                library.setProfile(p)
            }
        )
    }

    private var diagnosisDateBinding: Binding<Date> {
        Binding(
            get: { profile.diagnosisDate ?? Date() },
            set: { value in
                var p = profile
                p.diagnosisDate = value
                library.setProfile(p)
            }
        )
    }

    private var biologicalSexBinding: Binding<BiologicalSex?> {
        Binding(
            get: { profile.biologicalSex },
            set: { value in
                var p = profile
                p.biologicalSex = value
                p.biologicalSexSource = .manual
                library.setProfile(p)
            }
        )
    }

    private var dateOfBirthBinding: Binding<Date> {
        // 30 years ago is a reasonable seed when the user hasn't
        // entered anything yet — keeps the picker out of the
        // "you've selected today" corner case where age would read
        // as 0.
        Binding(
            get: {
                profile.dateOfBirth
                    ?? Calendar.current.date(byAdding: .year, value: -30, to: Date())
                    ?? Date()
            },
            set: { value in
                var p = profile
                p.dateOfBirth = value
                p.dateOfBirthSource = .manual
                library.setProfile(p)
            }
        )
    }

    // MARK: - Formatting

    /// Format a height in centimetres for display. Locales using
    /// imperial units render feet + inches (e.g. `5 ft 11 in`);
    /// metric locales render whole centimetres. Foundation's
    /// `Measurement` formatters do the locale dance for us.
    static func formatHeight(_ cm: Double) -> String {
        let measurement = Measurement(value: cm, unit: UnitLength.centimeters)
        return measurement.formatted(
            .measurement(width: .abbreviated, usage: .personHeight)
        )
    }

    /// Format a body mass in kilograms with the same locale-aware
    /// approach (`UnitMass` → pounds in the US, kilograms in
    /// metric locales).
    static func formatWeight(_ kg: Double) -> String {
        let measurement = Measurement(value: kg, unit: UnitMass.kilograms)
        return measurement.formatted(
            .measurement(width: .abbreviated, usage: .personWeight)
        )
    }

    /// Date of birth formatted with the user's locale, plus a
    /// computed age in parentheses so the row carries both the raw
    /// date the user can verify against Health and the derived age
    /// they probably actually care about.
    static func formatDateOfBirth(_ date: Date) -> String {
        let dateText = date.formatted(date: .abbreviated, time: .omitted)
        let years = Calendar.current.dateComponents([.year], from: date, to: Date()).year
        if let years, years >= 0 {
            return "\(dateText) (\(years))"
        }
        return dateText
    }
}
