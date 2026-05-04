import SwiftUI
import SnorecardKit

/// Per-night Sleep Journal surface. Free-form text plus a 1–5
/// subjective rating and a user-asserted tag list, persisted to
/// the iCloud sidecar via `Library.setNote` / `setSubjectiveScore`
/// / `setUserTags`. Typing still autosaves on a 750 ms debounce so
/// keystrokes don't churn iCloud.
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
    /// In-memory mirror of the user's subjective rating. `nil`
    /// means unrated; 1–5 otherwise.
    @State private var score: Int?
    /// Last-saved rating, used to suppress the write that would
    /// otherwise fire when the `.task` handler loads a different
    /// day's value into `score`.
    @State private var savedScore: Int?
    /// In-memory mirror of the user's asserted tags. `nil` means
    /// "fall back to AI extraction"; a (possibly empty) array means
    /// the user has explicitly asserted this set.
    @State private var userTags: [NoteTag]?
    /// Last-saved tag list, used to suppress the write that would
    /// otherwise fire when the `.task` handler loads a different
    /// day's value into `userTags`.
    @State private var savedUserTags: [NoteTag]?
    /// Raw AI-extracted tags surfaced alongside the user's list
    /// when the user hasn't overridden. Lets the user see what the
    /// extractor found and optionally accept it as their own.
    @State private var extractedTags: [NoteTag] = []

    var body: some View {
        #if os(iOS)
        // Match `DailySettingsInspector` / `SessionListSheet`: a fresh
        // NavigationStack with `.padding(.top, 12)` so the iOS sheet
        // header sits at the same vertical position across all the
        // day-level inspectors. macOS falls through to the bare
        // content because `ContentView` already wraps it with the
        // shared inspector chrome.
        NavigationStack {
            content
                .padding(.top, 12)
                .navigationBarTitleDisplayMode(.inline)
        }
        #else
        content
        #endif
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                InspectorPaneHeader(
                    title: "Sleep Journal",
                    caption: dateCaption
                )
                if hasAnyContent {
                    Button {
                        text = ""
                        score = nil
                        userTags = []
                    } label: {
                        Label("Clear", systemImage: "eraser")
                            .labelStyle(.iconOnly)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear this night's rating, tags, and journal entry")
                }
            }
            #if os(iOS)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            #endif

            ratingRow
                #if os(iOS)
                .padding(.horizontal, 16)
                #endif
            tagRow
                #if os(iOS)
                .padding(.horizontal, 16)
                #endif

            JournalEditor(
                placeholder: "How did you sleep? Add any context about this night…",
                text: $text
            )
            #if os(iOS)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            #endif
        }
        .task(id: day.id) {
            // When the viewed day changes, flush any pending save
            // for the previous day and load the new one's note.
            saveTask?.cancel()
            let loaded = library.note(for: day)
            text = loaded?.text ?? ""
            savedText = text
            score = loaded?.subjectiveScore
            savedScore = score
            userTags = loaded?.userTags
            savedUserTags = userTags
            extractedTags = loaded?.extractedTags ?? []
        }
        .onChange(of: text) { _, newValue in
            scheduleAutosave(newValue: newValue)
        }
        .onChange(of: score) { _, newValue in
            guard newValue != savedScore else { return }
            library.setSubjectiveScore(newValue, for: day)
            savedScore = newValue
        }
        .onChange(of: userTags) { _, newValue in
            guard newValue != savedUserTags else { return }
            library.setUserTags(newValue, for: day)
            savedUserTags = newValue
        }
        .onDisappear {
            // Force an immediate save on navigation away so the
            // user never loses the last few characters they typed
            // within the debounce window. Rating and tags already
            // persist synchronously in their `onChange` handlers.
            saveTask?.cancel()
            flushIfChanged(text)
        }
    }

    // MARK: - Header

    /// Date caption below the "Sleep Journal" title — same
    /// formatting used everywhere else in the inspector set.
    private var dateCaption: String {
        day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// True when any piece of the journal has content worth
    /// clearing. Drives the Clear button's visibility.
    private var hasAnyContent: Bool {
        !text.isEmpty
            || score != nil
            || !(userTags ?? []).isEmpty
    }

    // MARK: - Rating

    @ViewBuilder
    private var ratingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your rating")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let score {
                    Text(ratingLabel(for: score))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap to rate")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        // Tapping the same value a second time
                        // clears the rating, matching how iOS
                        // stars behave in Music / Photos.
                        if score == value {
                            score = nil
                        } else {
                            score = value
                        }
                    } label: {
                        Image(systemName: value <= (score ?? 0) ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(value <= (score ?? 0) ? Color.yellow : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(value) of 5")
                }
            }
        }
    }

    private func ratingLabel(for value: Int) -> String {
        switch value {
        case 1: return "Terrible"
        case 2: return "Poor"
        case 3: return "OK"
        case 4: return "Good"
        case 5: return "Great"
        default: return ""
        }
    }

    // MARK: - Tags

    @ViewBuilder
    private var tagRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tags")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !extractedTags.isEmpty && userTags == nil {
                    Button {
                        // Accept the AI extraction as the user's
                        // own assertion so the picker switches out
                        // of the "AI-detected" mode and into the
                        // standard manual mode.
                        userTags = extractedTags
                    } label: {
                        Label("Use AI tags", systemImage: "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }

            tagChips

            Menu {
                ForEach(NoteTagCategory.allCases, id: \.self) { category in
                    Section(category.displayLabel) {
                        ForEach(category.tags, id: \.self) { tag in
                            Button {
                                toggleTag(tag)
                            } label: {
                                if isSelected(tag) {
                                    Label(tag.displayLabel, systemImage: "checkmark")
                                } else {
                                    Text(tag.displayLabel)
                                }
                            }
                        }
                    }
                }
            } label: {
                Label(tagMenuLabel, systemImage: "tag")
                    .font(.callout)
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    /// Chip row showing the currently-selected tags. When the user
    /// hasn't asserted a list, the AI-extracted tags are shown with
    /// a subtle style so the reader knows they were detected rather
    /// than asserted.
    @ViewBuilder
    private var tagChips: some View {
        let displayed = userTags ?? extractedTags
        if displayed.isEmpty {
            Text(userTags == nil
                 ? "No tags detected yet."
                 : "No tags for this night.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(displayed, id: \.self) { tag in
                    tagChip(tag)
                }
            }
        }
    }

    @ViewBuilder
    private func tagChip(_ tag: NoteTag) -> some View {
        let isAsserted = userTags != nil
        HStack(spacing: 4) {
            if !isAsserted {
                Image(systemName: "sparkles")
                    .font(.caption2)
            }
            Text(tag.displayLabel)
                .font(.caption)
            if isAsserted {
                Button {
                    toggleTag(tag)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(tag.displayLabel) tag")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.primary.opacity(isAsserted ? 0.08 : 0.05))
        )
        .overlay(
            Capsule().stroke(
                Color.primary.opacity(isAsserted ? 0.12 : 0.08),
                lineWidth: 0.5
            )
        )
    }

    private var tagMenuLabel: String {
        let count = (userTags ?? []).count
        if userTags == nil { return "Add tag" }
        return count == 0 ? "Add tag" : "Add another tag"
    }

    private func isSelected(_ tag: NoteTag) -> Bool {
        (userTags ?? []).contains(tag)
    }

    /// Toggle `tag` in the user's asserted list. Promotes the list
    /// out of `nil` on first assertion so the user-override always
    /// takes precedence from this point forward — even if they
    /// later remove every tag, the resulting empty array still
    /// suppresses the AI extraction.
    private func toggleTag(_ tag: NoteTag) {
        var current = userTags ?? []
        if let idx = current.firstIndex(of: tag) {
            current.remove(at: idx)
        } else {
            current.append(tag)
        }
        userTags = current
    }

    // MARK: - Text autosave

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
