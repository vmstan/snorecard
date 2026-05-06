import Foundation
import SnorecardKit
import Observation
import os.log

private let importLog = Logger(subsystem: "com.vmstan.Snorecard", category: "Import")

/// Which section of the sidebar is active. A trends view sits above all the days.
enum SidebarSelection: Hashable, Sendable {
    case trends
    case day(Date)
}

/// Which per-day metric the sidebar renders on the right side of
/// each day row. Defaults to AHI (the therapy signal most users
/// check first) but can be swapped for any of the other three
/// values we already compute per night. Storing the choice as a
/// string lets us persist it via `UserDefaults` without a Codable
/// shim.
enum SidebarRowMetric: String, CaseIterable, Identifiable, Sendable {
    case ahi
    case glasgowIndex
    case maskPressure
    case sessions

    var id: String { rawValue }

    /// Long form used in the Settings picker — describes the metric
    /// the way it's referred to elsewhere in the app.
    var displayName: String {
        switch self {
        case .ahi:           return "AHI"
        case .glasgowIndex:  return "Glasgow Index"
        case .maskPressure:  return "Mask Pressure"
        case .sessions:      return "Sessions"
        }
    }

    /// Short caption rendered under the value in the sidebar row.
    /// Chosen so the two-line stack still fits the narrow right
    /// column on iPhone without squeezing the weekday / usage
    /// stack to its left.
    var rowCaption: String {
        switch self {
        case .ahi:           return "AHI"
        case .glasgowIndex:  return "Glasgow"
        case .maskPressure:  return "Pressure"
        case .sessions:      return "Sessions"
        }
    }
}

/// Named colour scheme for apnea / hypopnea event markers and every
/// palette-aware chart across the app. `.topher` is the default
/// (WCAG-friendly iOS-primary set); `.nick` and `.oscar` swap in
/// alternative schemes requested by users who prefer those hues.
/// The enum lives here (no SwiftUI import) and the Color resolution
/// is added via an extension in `PlatformColor.swift` so Library
/// stays dependency-free.
enum EventColorPalette: String, CaseIterable, Identifiable, Sendable {
    case topher
    case nick
    case oscar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topher: return "Topher"
        case .nick:   return "Nick"
        case .oscar:  return "Oscar"
        }
    }
}

/// User-facing label for "CA" (the central-apnea / clear-airway
/// category). ResMed and most CPAP literature uses "Central Apnea";
/// SleepHQ / OSCAR / sleep clinicians often prefer "Clear Airway"
/// because the central label can mis-suggest a brain-stem origin
/// when in practice CA events are most often arousal-related on
/// CPAP therapy. Default is "Clear Airway" — matches the term the
/// user would see in OSCAR and most online discussions. Whether
/// CA events appear at all is governed by `Library.showsCentralEvents`,
/// not by this enum.
enum CentralEventLabel: String, CaseIterable, Identifiable, Sendable {
    case clearAirway
    case centralApnea

    var id: String { rawValue }

    /// Long form used in legends, AI narratives, and stat-card
    /// labels. Reads naturally inline ("3 Clear Airway events").
    var displayName: String {
        switch self {
        case .clearAirway: return "Clear Airway"
        case .centralApnea: return "Central Apnea"
        }
    }

    /// Short form for the event donut and any width-constrained
    /// chip. Both labels share the "CA" abbreviation, so this
    /// is constant across the two cases.
    var shortName: String { "CA" }
}

/// User-facing category for a PAP device — shown in the Settings
/// Device section as a dropdown, used anywhere copy refers to the
/// machine generically ("this CPAP", "this Bilevel"), and synced
/// per-serial via iCloud so the user only picks once. `infer(from:)`
/// handles the standard ResMed product-name patterns so most devices
/// resolve correctly without the user touching the picker.
///
/// Two top-level categories the user actually thinks in: CPAP
/// (single-pressure machines, including auto-titrating "APAP"
/// variants) and Bilevel (separate IPAP / EPAP, including VAuto,
/// S / T / ST, and ASV servo-ventilators). The clinical distinction
/// between Bilevel and ASV doesn't change anything Snorecard
/// surfaces, so it stays out of the picker.
enum DeviceType: String, CaseIterable, Identifiable, Sendable {
    case cpap = "CPAP"
    case bipap = "BiPAP"

    var id: String { rawValue }

    /// Long form for pickers and prose. The bilevel rawValue stays
    /// "BiPAP" for KVS compatibility with existing user picks; the
    /// label the user sees is "Bilevel".
    var displayName: String {
        switch self {
        case .cpap:  return "CPAP"
        case .bipap: return "Bilevel"
        }
    }

    /// Best-effort mapping from a ResMed product name (e.g.
    /// "AirSense 10 AutoSet", "AirCurve 10 VAuto") to a `DeviceType`.
    /// Returns `nil` on unknown names so callers can decide whether
    /// to fall back to a default rather than guess silently.
    ///
    /// Auto-detection only resolves CPAP and Bilevel — every
    /// AirSense lands on CPAP, every AirCurve (including ASV
    /// variants) lands on Bilevel. ASV is never inferred; users
    /// who run a servo-ventilator pick it from the Type dropdown
    /// once and the choice rides iCloud KVS to their other devices.
    static func infer(fromProductName name: String?) -> DeviceType? {
        guard let name else { return nil }
        let lower = name.lowercased()
        if lower.contains("aircurve") { return .bipap }
        if lower.contains("airsense") { return .cpap }
        // Keyword fallbacks for older / relabelled models where
        // the family prefix is missing.
        if lower.contains("vauto") || lower.contains("bilevel") || lower.contains("bipap") {
            return .bipap
        }
        if lower.contains("autoset") || lower.contains("apap") || lower.contains("cpap") {
            return .cpap
        }
        return nil
    }
}

/// App-wide state: which SD card is loaded, which day is selected, and
/// whether an iCloud sync is in flight. Platform-agnostic — all picker
/// UI lives in the view layer so this type can compile unchanged on
/// macOS, iOS, and iPadOS.
@Observable
@MainActor
final class Library {
    enum LoadState: Equatable {
        case empty
        case loading(URL)
        /// Transitional state — we have enough of the card to paint
        /// the sidebar (from either a persisted snapshot or a quick
        /// structure-only scan) but per-day aggregates are still
        /// filling in. Views treat this the same as `.loaded`.
        case hydrating(ResMedSDCard)
        case loaded(ResMedSDCard)
        case failed(String)
    }

    var state: LoadState = .empty
    var selection: SidebarSelection? = nil
    /// `true` while the initial launch probe is deciding what to
    /// open. Stays `true` until `loadLastOpenedIfPossible()`
    /// finishes its iCloud + snapshot + local-fallback sweep, so
    /// the UI can show a "Opening Snorecard…" splash instead of
    /// flashing the empty-state "No SD Card" screen before the
    /// probe has had a chance to pick a folder.
    var isInitialProbing: Bool = true
    /// Map of CPAP serial number → custom display name. Backed by
    /// `NSUbiquitousKeyValueStore` so the override syncs automatically
    /// across all of the user's Macs and iOS devices.
    private(set) var deviceNameOverrides: [String: String] = [:]
    /// Map of CPAP serial number → per-device compliance-hour target.
    /// The threshold (in hours/night) used to decide whether a night
    /// counts toward compliance and to tint the usage chart. Unset
    /// serials fall back to `Library.defaultComplianceHours`, which
    /// matches the insurer/clinic standard. Synced via iCloud KVS so
    /// the user doesn't have to re-pick their target on each device.
    private(set) var complianceTargets: [String: Double] = [:]
    /// Map of CPAP serial number → user-selected `DeviceType` raw
    /// value. Only populated when the user explicitly overrides the
    /// auto-detected type, so absence means "trust what `DeviceType`
    /// infers from the product name". Synced via iCloud KVS so the
    /// pick follows the user across devices.
    private(set) var deviceTypeOverrides: [String: String] = [:]
    /// User's curated list of physical masks. Edited from
    /// Settings → Mask, persisted as a JSON-encoded array under one
    /// KVS key so the catalog rides iCloud across every device.
    /// Per-session mask assignments live in `DailyNote.sessionMasks`,
    /// not here — this is the "your masks" rolodex, not the "which
    /// mask did I wear last Tuesday" log.
    private(set) var userMasks: [Mask] = []
    /// `Mask.id` of the mask that should be stamped onto newly
    /// imported sessions when the journal sidecar is first created.
    /// Synced via iCloud KVS so changing the default on iPhone also
    /// stamps imports done on macOS. `nil` when the user hasn't
    /// chosen a default — fresh imports then carry no mask metadata
    /// until the user assigns one.
    private(set) var defaultMaskID: UUID?
    /// User profile (name, height, weight, untreated AHI, diagnosis
    /// date). Populated by Settings → Profile and
    /// optionally by an Apple Health import on iOS. Synced via
    /// iCloud KVS so the same fields appear on every device the
    /// user signs into.
    public private(set) var userProfile: UserProfile = .empty
    /// Non-nil while iCloud placeholder sidecars are being fetched so
    /// the sidebar can show a "Downloading from iCloud — N/M" hint
    /// instead of looking stuck.
    var cloudPrefetchProgress: CloudPrefetcher.Progress?

    /// Single source of truth for whether Apple Intelligence can be
    /// used in this session. Views gate every narrative-backed
    /// surface on `intelligence.isReady`.
    let intelligence: IntelligenceAvailability
    /// Narration backend for every Intelligence-backed surface.
    /// Views still call through `library.narration` but only
    /// after checking `library.intelligence.isReady`; if the
    /// model becomes unavailable mid-call, the service throws
    /// and the caller hides the surface.
    let narration: NarrationService

    /// Apple Watch sleep-stage coordinator. Owns auth state, the
    /// in-memory `summaryByDate` map, and the backfill/observer
    /// pipeline. Views read from this directly via `library.healthSleep`
    /// instead of holding their own HealthKit handles.
    let healthSleep: HealthKitSleepCoordinator

    /// Set to `true` when the first-launch flow needs `ContentView` to
    /// present the "Pull sleep stages from Apple Watch?" prompt. The
    /// view clears the flag (and writes the persisted "shown" key)
    /// when the dialog is answered or dismissed.
    var pendingHealthKitPrompt: Bool = false

    /// Non-nil while the user has opened a metric explanation
    /// by tapping a stat card. Drives the iOS sheet and the
    /// macOS inspector pane from a single source of truth so
    /// both platforms share one routing path. Cleared by the
    /// sheet/inspector when it closes.
    var pendingExplain: ExplainRequest? = nil

    /// Non-nil while the user has opened the Trends' Sleep
    /// Analysis from the toolbar / menu. Carries the stats,
    /// range bounds, and filtered day list so
    /// `TrendNarrativeCard` can render without needing
    /// `TrendsView`'s local range state.
    var pendingTrendsAnalysis: TrendsAnalysisRequest? = nil

    /// Serial number → per-day tag-extraction task. Tracked here
    /// so a rapid note edit (750 ms autosave churning) cancels
    /// the in-flight extraction and reschedules rather than
    /// piling up sessions for the same note.
    private var pendingTagExtractions: [URL: Task<Void, Never>] = [:]

    private static let lastPathKey = "SnorecardLastSDPath"
    private static let deviceNamesKey = "deviceNameOverrides"
    private static let complianceTargetsKey = "complianceTargets"
    private static let deviceTypesKey = "deviceTypeOverrides"
    private static let userProfileKey = "userProfile"
    private static let lastOpenedSerialKey = "lastOpenedSerial"
    private static let backgroundReloadIntervalKey = "backgroundReloadIntervalMinutes"
    private static let sidebarSeverityColorsKey = "sidebarSeverityColorsEnabled"
    private static let sidebarRowMetricKey = "sidebarRowMetric"
    private static let eventColorPaletteKey = "eventColorPalette"
    private static let centralEventLabelKey = "centralEventLabel"
    private static let showsCentralEventsKey = "showsCentralEvents"
    private static let excludedSessionKeysKey = "excludedSessionKeys"
    private static let defaultJournalTagsKey = "defaultJournalTags"
    private static let appleWatchSleepEnabledKey = "appleWatchSleepEnabled"
    private static let appleWatchSleepPromptShownKey = "appleWatchSleepPromptShown"
    private static let userMasksKey = "userMasks"
    private static let defaultMaskIDKey = "defaultMaskID"

    /// Fallback target when the user hasn't set one for a device.
    /// 4 hours is the CMS/Medicare threshold and the one every
    /// ResMed + insurer dashboard uses, so it's the least-surprising
    /// default for a fresh card.
    static let defaultComplianceHours: Double = 4

    /// How often (minutes) to automatically re-run `reloadCurrent()`
    /// while the app is open. 15 min matches the cadence at which
    /// ResMed PAP devices flush new day folders to the SD card / the
    /// iCloud container, so users see fresh data without having to
    /// hit Reload manually after a nap or an early wake.
    static let defaultBackgroundReloadIntervalMinutes = 15

    /// Valid selections for the Advanced-settings picker. 0 disables
    /// the background refresh entirely; the rest march in 15-minute
    /// increments up to an hour.
    static let backgroundReloadIntervalChoices = [0, 15, 30, 45, 60]

    /// Current interval between automatic reloads, in minutes. Zero
    /// means disabled. Persisted per-device (local responsiveness
    /// preference — no reason to sync across machines). Setting this
    /// cancels any in-flight refresh task and restarts the loop with
    /// the new cadence.
    var backgroundReloadIntervalMinutes: Int {
        didSet {
            guard oldValue != backgroundReloadIntervalMinutes else { return }
            UserDefaults.standard.set(
                backgroundReloadIntervalMinutes,
                forKey: Self.backgroundReloadIntervalKey
            )
            restartBackgroundReload()
        }
    }

    /// Whether the sidebar tints each day's calendar glyph with an
    /// AHI-severity color (green/orange/red). Disabling falls back to
    /// the accent color so the sidebar reads as a flat list without
    /// the user having to squint past the traffic-light palette.
    /// Local-only preference — visual taste, not therapy data, so
    /// there's no reason to sync it across devices.
    var sidebarSeverityColorsEnabled: Bool {
        didSet {
            guard oldValue != sidebarSeverityColorsEnabled else { return }
            UserDefaults.standard.set(
                sidebarSeverityColorsEnabled,
                forKey: Self.sidebarSeverityColorsKey
            )
        }
    }

    /// Which metric the sidebar renders in each day's right-hand
    /// stack. Defaults to AHI but can be swapped for Glasgow Index,
    /// 95th-percentile mask pressure, or session count depending on
    /// what the user cares to scan by at a glance. Local-only.
    var sidebarRowMetric: SidebarRowMetric {
        didSet {
            guard oldValue != sidebarRowMetric else { return }
            UserDefaults.standard.set(
                sidebarRowMetric.rawValue,
                forKey: Self.sidebarRowMetricKey
            )
        }
    }

    /// Current colour scheme for OA / H / CA markers in the event
    /// donut, every palette-aware chart, and the themed stat-card
    /// severity tints. Defaults to `.topher` (iOS-primary set).
    /// Local-only — a visual preference, not sync-worthy.
    var eventColorPalette: EventColorPalette {
        didSet {
            guard oldValue != eventColorPalette else { return }
            UserDefaults.standard.set(
                eventColorPalette.rawValue,
                forKey: Self.eventColorPaletteKey
            )
        }
    }

    /// User-preferred long-form label for "CA" events. Drives the
    /// chart legend, the stat-card label, and the AI narrative
    /// terminology so the same naming reads consistently across
    /// the app. Defaults to `.clearAirway`. Local-only. The choice
    /// only matters when `showsCentralEvents` is true; flipping the
    /// toggle off and back on restores whatever label the user had
    /// picked before.
    var centralEventLabel: CentralEventLabel {
        didSet {
            guard oldValue != centralEventLabel else { return }
            UserDefaults.standard.set(
                centralEventLabel.rawValue,
                forKey: Self.centralEventLabelKey
            )
        }
    }

    /// Whether CA events should appear in charts, summaries, and
    /// AHI calculations. Defaults to true. Some users have been
    /// told by their clinician that their CA events are arousal
    /// artefacts unrelated to therapy and want them out of the
    /// number entirely; turning this off drops the CA segment from
    /// charts and subtracts the central index from every displayed
    /// AHI. Local-only — visual / clinical-framing preference.
    var showsCentralEvents: Bool {
        didSet {
            guard oldValue != showsCentralEvents else { return }
            UserDefaults.standard.set(
                showsCentralEvents,
                forKey: Self.showsCentralEventsKey
            )
        }
    }

    /// Per-session opt-outs keyed by `ResMedDataFile.sessionKey` (the
    /// `YYYYMMDD_HHMMSS` filename prefix). Excluded sessions are
    /// dropped from the day's aggregate so a brief mask test or
    /// daytime fitting doesn't contaminate AHI / usage / pressure
    /// stats. Local-only — the canonical disk cache stays unfiltered,
    /// and re-aggregation runs on top of it whenever the set changes.
    var excludedSessionKeys: Set<String> {
        didSet {
            guard oldValue != excludedSessionKeys else { return }
            UserDefaults.standard.set(
                Array(excludedSessionKeys).sorted(),
                forKey: Self.excludedSessionKeysKey
            )
        }
    }

    /// Tags the user wants auto-attached to every imported night.
    /// Applied in `load()` as each day's stats are backfilled, but
    /// only when the day has no existing journal sidecar — so manual
    /// edits (including an intentionally empty tag list) always win
    /// over this default. Synced via iCloud KVS so a user who picks
    /// defaults on iPhone gets the same auto-tagging when they
    /// import on macOS — without the sync, the import device never
    /// sees the picks made on the configuring device.
    var defaultJournalTags: Set<NoteTag> {
        didSet {
            guard oldValue != defaultJournalTags else { return }
            let kvs = NSUbiquitousKeyValueStore.default
            kvs.set(
                defaultJournalTags.map(\.rawValue).sorted(),
                forKey: Self.defaultJournalTagsKey
            )
            kvs.synchronize()
        }
    }

    private var backgroundReloadTask: Task<Void, Never>?

    init() {
        self.intelligence = IntelligenceAvailability()
        // Always wire up the Foundation-backed service — availability
        // is enforced at the view layer via `intelligence.isReady`.
        // If the model flips to unavailable mid-session, the service
        // throws `sessionFailed` and the caller hides its card.
        self.narration = FoundationNarrationService()

        // HealthKit coordinator. iOS only — macOS HealthKit sleep
        // sync from iPhone is unreliable in practice (sample
        // returns drop most multi-source data and lag the iPhone
        // store by hours), so we ship the feature as iOS-only.
        // The coordinator is still constructed on macOS but stays
        // permanently disabled, which keeps every Library API
        // reachable from shared view code without a `#if` at every
        // call site.
        #if os(iOS)
        let healthEnabled = UserDefaults.standard.bool(
            forKey: Self.appleWatchSleepEnabledKey
        )
        #else
        let healthEnabled = false
        #endif
        self.healthSleep = HealthKitSleepCoordinator(
            fetcher: HealthKitSleepFetcher(),
            isEnabled: healthEnabled
        )

        let storedInterval = UserDefaults.standard.object(
            forKey: Self.backgroundReloadIntervalKey
        ) as? Int
        self.backgroundReloadIntervalMinutes = Self.normalizedBackgroundReloadInterval(
            storedInterval ?? Self.defaultBackgroundReloadIntervalMinutes
        )

        // Default both sidebar appearance prefs to their "classic"
        // values — severity colors on, AHI in the right-hand column —
        // so an existing user sees no change after upgrading.
        if let storedSeverity = UserDefaults.standard.object(
            forKey: Self.sidebarSeverityColorsKey
        ) as? Bool {
            self.sidebarSeverityColorsEnabled = storedSeverity
        } else {
            self.sidebarSeverityColorsEnabled = true
        }

        if let rawMetric = UserDefaults.standard.string(
            forKey: Self.sidebarRowMetricKey
        ), let metric = SidebarRowMetric(rawValue: rawMetric) {
            self.sidebarRowMetric = metric
        } else {
            self.sidebarRowMetric = .ahi
        }

        // Legacy raw values ("default", "christopher", "chris") fall
        // through to `.topher` — the colours of the original
        // Christopher preset are what Topher now paints, so the
        // default set just adopts a new name on next launch.
        if let rawPalette = UserDefaults.standard.string(
            forKey: Self.eventColorPaletteKey
        ), let palette = EventColorPalette(rawValue: rawPalette) {
            self.eventColorPalette = palette
        } else {
            self.eventColorPalette = .topher
        }

        // Visibility lives on a separate Bool key so flipping the
        // Show CA Events toggle off and back on restores the user's
        // previously-picked label. An earlier iteration encoded
        // "disabled" as a third enum case; treat any leftover raw
        // value of that shape as "hidden + label defaulted to Clear
        // Airway" so users who set it during the prerelease don't
        // see a missing-case crash on first launch.
        let rawLabel = UserDefaults.standard.string(forKey: Self.centralEventLabelKey)
        if rawLabel == "disabled" {
            self.centralEventLabel = .clearAirway
            self.showsCentralEvents = false
        } else if let raw = rawLabel, let label = CentralEventLabel(rawValue: raw) {
            self.centralEventLabel = label
            self.showsCentralEvents = UserDefaults.standard.object(
                forKey: Self.showsCentralEventsKey
            ) as? Bool ?? true
        } else {
            self.centralEventLabel = .clearAirway
            self.showsCentralEvents = UserDefaults.standard.object(
                forKey: Self.showsCentralEventsKey
            ) as? Bool ?? true
        }

        if let stored = UserDefaults.standard.array(
            forKey: Self.excludedSessionKeysKey
        ) as? [String] {
            self.excludedSessionKeys = Set(stored)
        } else {
            self.excludedSessionKeys = []
        }

        let kvs = NSUbiquitousKeyValueStore.default
        deviceNameOverrides = kvs.dictionary(forKey: Self.deviceNamesKey)
            as? [String: String] ?? [:]
        complianceTargets = (kvs.dictionary(forKey: Self.complianceTargetsKey)
            as? [String: Double]) ?? [:]
        deviceTypeOverrides = kvs.dictionary(forKey: Self.deviceTypesKey)
            as? [String: String] ?? [:]
        userProfile = Self.decodeProfile(from: kvs.data(forKey: Self.userProfileKey))

        // Default tags default to empty so upgrading users don't
        // suddenly see every night pre-tagged. Raw values that no
        // longer exist in the taxonomy are dropped silently. KVS is
        // the source of truth; if it's empty but UserDefaults has
        // values from a build that stored locally, migrate them up
        // so the user's existing picks ride iCloud without needing
        // to be re-set.
        if let rawTags = kvs.array(forKey: Self.defaultJournalTagsKey) as? [String] {
            self.defaultJournalTags = Set(rawTags.compactMap(NoteTag.init(rawValue:)))
        } else if let legacy = UserDefaults.standard.array(
            forKey: Self.defaultJournalTagsKey
        ) as? [String] {
            self.defaultJournalTags = Set(legacy.compactMap(NoteTag.init(rawValue:)))
            kvs.set(legacy, forKey: Self.defaultJournalTagsKey)
            UserDefaults.standard.removeObject(forKey: Self.defaultJournalTagsKey)
        } else {
            self.defaultJournalTags = []
        }

        self.userMasks = Self.decodeMasks(from: kvs.data(forKey: Self.userMasksKey))
        if let raw = kvs.string(forKey: Self.defaultMaskIDKey),
           let uuid = UUID(uuidString: raw),
           userMasks.contains(where: { $0.id == uuid }) {
            self.defaultMaskID = uuid
        } else {
            self.defaultMaskID = nil
        }

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshiCloudPreferences()
            }
        }
        // Kick off an initial pull so any value already synced to this
        // device is picked up on first launch.
        kvs.synchronize()

        restartBackgroundReload()
    }

    /// Clamp a stored/externally-supplied interval to the picker's
    /// allowed choices so a corrupted UserDefaults entry (or a build
    /// from before a future picker change) can't produce a timer at
    /// an unexpected cadence.
    private static func normalizedBackgroundReloadInterval(_ minutes: Int) -> Int {
        backgroundReloadIntervalChoices.contains(minutes)
            ? minutes
            : defaultBackgroundReloadIntervalMinutes
    }

    /// Cancel any in-flight auto-reload task and — if the user hasn't
    /// disabled the feature — spawn a fresh one that re-runs
    /// `reloadCurrent()` on the configured cadence. Skips firing
    /// while a load is already in flight so a slow refresh can't
    /// stack with the next tick.
    private func restartBackgroundReload() {
        backgroundReloadTask?.cancel()
        backgroundReloadTask = nil
        let minutes = backgroundReloadIntervalMinutes
        guard minutes > 0 else { return }
        let sleepNanos = UInt64(minutes) * 60 * 1_000_000_000
        backgroundReloadTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sleepNanos)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    switch self.state {
                    case .loading, .hydrating:
                        // A user-initiated or prior auto reload is
                        // still resolving — skip this tick rather
                        // than stacking work on the import pipeline.
                        return
                    default:
                        self.reloadCurrent()
                    }
                }
            }
        }
    }

    var card: ResMedSDCard? {
        switch state {
        case .loaded(let card), .hydrating(let card): return card
        default: return nil
        }
    }

    /// `true` while a progressive backfill is still in flight — used
    /// by views that want to show a subtle "finishing…" indicator.
    var isHydrating: Bool {
        if case .hydrating = state { return true }
        return false
    }

    var selectedDay: ResMedDay? {
        guard let card, case .day(let id) = selection else { return nil }
        return card.days.first { $0.id == id }
    }

    // MARK: - Device name overrides

    /// The user-facing name for a loaded card. Prefers the iCloud-synced
    /// override (keyed on serial), falling back to the ResMed product name
    /// and finally a generic label.
    func displayName(for card: ResMedSDCard) -> String {
        if let serial = card.identification?.serialNumber,
           let override = deviceNameOverrides[serial],
           !override.isEmpty {
            return override
        }
        return card.identification?.productName
            ?? "ResMed \(deviceType(for: card).displayName)"
    }

    /// Set or clear a custom name for a given serial. Passing an empty /
    /// whitespace-only string removes the override.
    func setDeviceName(_ name: String?, for serial: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            deviceNameOverrides[serial] = trimmed
        } else {
            deviceNameOverrides.removeValue(forKey: serial)
        }
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.set(deviceNameOverrides, forKey: Self.deviceNamesKey)
        kvs.synchronize()
    }

    private func refreshiCloudPreferences() {
        let kvs = NSUbiquitousKeyValueStore.default
        deviceNameOverrides = kvs.dictionary(forKey: Self.deviceNamesKey)
            as? [String: String] ?? [:]
        complianceTargets = (kvs.dictionary(forKey: Self.complianceTargetsKey)
            as? [String: Double]) ?? [:]
        deviceTypeOverrides = kvs.dictionary(forKey: Self.deviceTypesKey)
            as? [String: String] ?? [:]
        userProfile = Self.decodeProfile(from: kvs.data(forKey: Self.userProfileKey))
        if let rawTags = kvs.array(forKey: Self.defaultJournalTagsKey) as? [String] {
            // Skip the assignment when the value hasn't actually
            // moved — the property's didSet would otherwise echo the
            // change straight back to KVS.
            let resolved = Set(rawTags.compactMap(NoteTag.init(rawValue:)))
            if resolved != defaultJournalTags {
                defaultJournalTags = resolved
            }
        }
        userMasks = Self.decodeMasks(from: kvs.data(forKey: Self.userMasksKey))
        if let raw = kvs.string(forKey: Self.defaultMaskIDKey),
           let uuid = UUID(uuidString: raw),
           userMasks.contains(where: { $0.id == uuid }) {
            defaultMaskID = uuid
        } else {
            defaultMaskID = nil
        }
    }

    /// Decode a `UserProfile` payload from KVS-stored bytes,
    /// falling back to `.empty` on any failure (corrupt JSON, key
    /// missing, schema drift). Stable JSON encoding so two
    /// devices that round-trip the same profile end up with the
    /// same KVS bytes.
    private static func decodeProfile(from data: Data?) -> UserProfile {
        guard let data else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(UserProfile.self, from: data)) ?? .empty
    }

    /// Encode a `UserProfile` payload for KVS, returning `nil` if
    /// encoding throws (treated upstream as "leave the previous
    /// KVS value alone" rather than overwriting with a corrupt
    /// blob).
    private static func encodeProfile(_ profile: UserProfile) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(profile)
    }

    /// Decode the user's saved mask catalog from a KVS payload,
    /// falling back to an empty array on missing/corrupt data so a
    /// schema bump on another device can't crash an older client.
    private static func decodeMasks(from data: Data?) -> [Mask] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([Mask].self, from: data)) ?? []
    }

    /// Encode the mask catalog for KVS. `.sortedKeys` so two devices
    /// that round-trip the same catalog produce identical bytes —
    /// keeps KVS from churning notifications on no-op writes.
    private static func encodeMasks(_ masks: [Mask]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(masks)
    }

    // MARK: - User profile

    /// Replace the stored profile and persist to iCloud KVS so the
    /// new fields propagate to every device the user signs into.
    /// `setProfile` is the single entry point for both manual
    /// edits and Health imports — the source flags inside
    /// `UserProfile` carry which fields the user can edit on the
    /// other device.
    public func setProfile(_ profile: UserProfile) {
        guard userProfile != profile else { return }
        userProfile = profile
        if let data = Self.encodeProfile(profile) {
            let kvs = NSUbiquitousKeyValueStore.default
            kvs.set(data, forKey: Self.userProfileKey)
            kvs.synchronize()
        }
    }

    /// Pull the latest height + body mass from Apple Health and
    /// fold them into the existing profile, marking each imported
    /// field as `.healthKit` so the UI locks it. Other fields stay
    /// untouched. iOS only — macOS skips the import entirely
    /// (HealthKit reads on Mac are unreliable enough that the
    /// rest of the integration is read-only-from-sidecars; profile
    /// follows the same rule).
    public func importProfileFromHealthKit() async {
        #if os(iOS)
        let fetcher = HealthKitProfileFetcher()
        let result: ProfileFetchResult
        do {
            result = try await fetcher.fetchProfile()
        } catch {
            return
        }
        var updated = userProfile
        if let height = result.heightCm {
            updated.heightCm = height
            updated.heightSource = .healthKit
        }
        if let weight = result.weightKg {
            updated.weightKg = weight
            updated.weightSource = .healthKit
        }
        if let sex = result.biologicalSex {
            updated.biologicalSex = sex
            updated.biologicalSexSource = .healthKit
        }
        if let dob = result.dateOfBirth {
            updated.dateOfBirth = dob
            updated.dateOfBirthSource = .healthKit
        }
        setProfile(updated)
        #endif
    }

    // MARK: - Compliance target

    /// Hours-per-night threshold the user considers a "compliant"
    /// night for this device. Falls back to `defaultComplianceHours`
    /// when the user hasn't customized it. Clamps on read as well as
    /// on write so an anomalous KVS payload from another device
    /// (corruption, or a compromised iCloud account) can't drive UI
    /// that assumes the range.
    func complianceTarget(for serial: String?) -> Double {
        guard let serial,
              let value = complianceTargets[serial],
              value.isFinite
        else {
            return Self.defaultComplianceHours
        }
        return Self.clampedComplianceHours(value)
    }

    /// Pin `hours` to the same 1–12h range the Stepper offers so
    /// both the reader and writer agree on what "valid" means.
    private static func clampedComplianceHours(_ hours: Double) -> Double {
        min(max(hours, 1), 12)
    }

    // MARK: - Device type

    /// Resolved `DeviceType` for a card. Prefers the iCloud-synced
    /// user override, falls back to `DeviceType.infer` on the product
    /// name, and finally lands on `.cpap` when neither is available.
    /// `.cpap` is the least-surprising fallback since plain CPAP is
    /// the baseline therapy every other PAP mode builds on.
    func deviceType(for card: ResMedSDCard?) -> DeviceType {
        if let serial = card?.identification?.serialNumber,
           let raw = deviceTypeOverrides[serial],
           let type = DeviceType(rawValue: raw) {
            return type
        }
        if let inferred = DeviceType.infer(
            fromProductName: card?.identification?.productName
        ) {
            return inferred
        }
        return .cpap
    }

    /// Resolved type for a bare serial — used by views that only
    /// have a serial in hand. Shares resolution with the card-based
    /// lookup when the serial belongs to the currently-loaded card
    /// so the two entry points never disagree.
    func deviceType(for serial: String?) -> DeviceType {
        if serial == card?.identification?.serialNumber {
            return deviceType(for: card)
        }
        if let serial, let raw = deviceTypeOverrides[serial],
           let type = DeviceType(rawValue: raw) {
            return type
        }
        return .cpap
    }

    /// Persist a user-picked `DeviceType` for a serial. When the pick
    /// matches what `DeviceType.infer` would produce from the product
    /// name, the override is cleared so iCloud KVS doesn't store
    /// values that just duplicate inference — mirrors the compliance-
    /// target pattern.
    func setDeviceType(_ type: DeviceType, for serial: String, productName: String?) {
        let inferred = DeviceType.infer(fromProductName: productName)
        if type == inferred {
            deviceTypeOverrides.removeValue(forKey: serial)
        } else {
            deviceTypeOverrides[serial] = type.rawValue
        }
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.set(deviceTypeOverrides, forKey: Self.deviceTypesKey)
        kvs.synchronize()
    }

    /// Persist a new compliance target for a serial. Passing the
    /// default value clears the override so we don't bloat iCloud
    /// KVS with entries that duplicate the fallback.
    func setComplianceTarget(_ hours: Double, for serial: String) {
        let clamped = Self.clampedComplianceHours(hours)
        if clamped == Self.defaultComplianceHours {
            complianceTargets.removeValue(forKey: serial)
        } else {
            complianceTargets[serial] = clamped
        }
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.set(complianceTargets, forKey: Self.complianceTargetsKey)
        kvs.synchronize()
    }

    // MARK: - Masks

    /// Look up a mask by id. `nil` for stale references (a mask the
    /// user deleted after it was stamped onto a session) so callers
    /// can render a graceful "Unknown" affordance without crashing.
    func mask(id: UUID?) -> Mask? {
        guard let id else { return nil }
        return userMasks.first { $0.id == id }
    }

    /// Append a new mask to the user's catalog. Persists to KVS so
    /// the addition propagates to every signed-in device, and — when
    /// no default has been picked yet — also promotes this first
    /// mask to the default-for-imports slot so the user doesn't have
    /// to make two picks to start labelling sessions.
    func addMask(_ mask: Mask) {
        userMasks.append(mask)
        persistMasks()
        if defaultMaskID == nil {
            setDefaultMaskID(mask.id)
        }
    }

    /// Replace an existing mask in the catalog. No-op when the id
    /// isn't present — protects against a stale UI binding writing
    /// back after the underlying mask was deleted on another device.
    func updateMask(_ mask: Mask) {
        guard let idx = userMasks.firstIndex(where: { $0.id == mask.id })
        else { return }
        guard userMasks[idx] != mask else { return }
        userMasks[idx] = mask
        persistMasks()
    }

    /// Remove a mask from the catalog. Clears the
    /// default-mask-for-imports pointer when it was pointing at the
    /// deleted record. Per-session sidecar entries still referencing
    /// this id are intentionally not swept — they're scattered across
    /// hundreds of day folders on iCloud Drive, and the resolver
    /// returns `nil` for stale ids so the UI degrades gracefully.
    /// Picking any other mask on the affected sessions overwrites
    /// the orphan reference in place.
    func deleteMask(id: UUID) {
        userMasks.removeAll { $0.id == id }
        persistMasks()
        if defaultMaskID == id {
            setDefaultMaskID(nil)
        }
    }

    /// Set or clear the mask stamped onto newly imported sessions.
    /// Persists to KVS as the mask UUID's `uuidString` so other
    /// devices pick up the new default on their next sync.
    func setDefaultMaskID(_ id: UUID?) {
        guard defaultMaskID != id else { return }
        defaultMaskID = id
        let kvs = NSUbiquitousKeyValueStore.default
        if let id {
            kvs.set(id.uuidString, forKey: Self.defaultMaskIDKey)
        } else {
            kvs.removeObject(forKey: Self.defaultMaskIDKey)
        }
        kvs.synchronize()
    }

    /// Persist `userMasks` to KVS. JSON-encoded as a single Data
    /// blob so the whole catalog round-trips atomically.
    private func persistMasks() {
        let kvs = NSUbiquitousKeyValueStore.default
        if let data = Self.encodeMasks(userMasks) {
            kvs.set(data, forKey: Self.userMasksKey)
            kvs.synchronize()
        }
    }

    /// Resolved mask for a given session. Reads the per-session
    /// override stamped into the day's `.snorecard-notes.json`
    /// sidecar, falling back to `nil` when no entry has been
    /// recorded. The default-mask is *not* applied at read time —
    /// stamping happens once at import (see
    /// `applyDefaultJournalTagsIfNeeded`) so changing the default
    /// later doesn't retroactively re-label historical sessions.
    func mask(forSessionKey sessionKey: String, on day: ResMedDay) -> Mask? {
        guard let folder = day.files.first?.url.deletingLastPathComponent()
        else { return nil }
        let note = DailyNotesCache.load(for: folder)
        guard let raw = note?.sessionMasks?[sessionKey],
              let uuid = UUID(uuidString: raw)
        else { return nil }
        return mask(id: uuid)
    }

    /// Persist `maskID` as the mask the user wore for `sessionKey`
    /// on `day`. Passing `nil` removes any existing assignment for
    /// that session (the row's mask falls back to "no mask"). Reads
    /// the existing sidecar before writing so journal text, tags,
    /// and rating ride through unchanged.
    func setMask(
        _ maskID: UUID?,
        forSessionKey sessionKey: String,
        on day: ResMedDay
    ) {
        guard let folder = day.files.first?.url.deletingLastPathComponent()
        else { return }
        let prior = DailyNotesCache.load(for: folder) ?? DailyNote(text: "")
        var masks = prior.sessionMasks ?? [:]
        if let maskID {
            masks[sessionKey] = maskID.uuidString
        } else {
            masks.removeValue(forKey: sessionKey)
        }
        DailyNotesCache.save(
            DailyNote(
                text: prior.text,
                updatedAt: Date(),
                extractedTags: prior.extractedTags,
                tagsInputHash: prior.tagsInputHash,
                taxonomyVersion: prior.taxonomyVersion,
                userTags: prior.userTags,
                subjectiveScore: prior.subjectiveScore,
                sessionMasks: masks.isEmpty ? nil : masks
            ),
            to: folder
        )
    }

    /// Stamp `maskID` onto every session of every day on the loaded
    /// card whose date falls within `dateRange` (inclusive). Used by
    /// the "Apply to existing sessions" flow in Settings → Mask so
    /// users can backfill mask history after creating a new mask
    /// record. Each day's sidecar is read just before being written
    /// to narrow the window for stomping a concurrent journal edit
    /// on another device. Returns the number of sessions stamped so
    /// the UI can surface a "n sessions updated" confirmation.
    @discardableResult
    func applyMaskToSessions(
        _ maskID: UUID,
        in dateRange: ClosedRange<Date>?
    ) -> Int {
        guard let card else { return 0 }
        let raw = maskID.uuidString
        var updatedSessions = 0
        for day in card.days {
            if let dateRange, !dateRange.contains(day.date) { continue }
            guard let folder = day.files.first?.url.deletingLastPathComponent()
            else { continue }
            let dayKeys = day.files.compactMap(\.sessionKey)
            // Deduplicate — BRP/EVE/PLD share a session key.
            let uniqueKeys = Array(Set(dayKeys))
            guard !uniqueKeys.isEmpty else { continue }
            let prior = DailyNotesCache.load(for: folder) ?? DailyNote(text: "")
            var masks = prior.sessionMasks ?? [:]
            for key in uniqueKeys {
                if masks[key] != raw {
                    masks[key] = raw
                    updatedSessions += 1
                }
            }
            DailyNotesCache.save(
                DailyNote(
                    text: prior.text,
                    updatedAt: Date(),
                    extractedTags: prior.extractedTags,
                    tagsInputHash: prior.tagsInputHash,
                    taxonomyVersion: prior.taxonomyVersion,
                    userTags: prior.userTags,
                    subjectiveScore: prior.subjectiveScore,
                    sessionMasks: masks.isEmpty ? nil : masks
                ),
                to: folder
            )
        }
        return updatedSessions
    }

    /// Re-run the scan on the currently loaded card's folder without
    /// discarding the cache. Picks up day folders and sidecars that
    /// have synced down from iCloud since the initial load.
    func reloadCurrent() {
        guard let url = card?.rootURL else { return }
        load(url)
    }

    /// Async variant of `reloadCurrent` that returns only once the
    /// load pipeline has settled (prefetch + scan + backfill all
    /// finished). Pull-to-refresh needs this shape so the spinner
    /// stays up through the refresh rather than dismissing the
    /// instant the detached task kicks off.
    func reloadCurrentAndWait() async {
        guard let url = card?.rootURL else { return }
        load(url)
        // Poll the `@Observable` state until it leaves the in-flight
        // cases. 150 ms is a comfortable balance between snappy
        // dismissal on fast refreshes and not churning the main run
        // loop on slow ones.
        while true {
            switch state {
            case .loaded, .failed, .empty:
                return
            case .loading, .hydrating:
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
        }
    }


    /// Remove every `.snorecard-stats.json` sidecar inside the currently
    /// loaded card's DATALOG tree and trigger a full re-import. Forces
    /// the next scan to recompute every day from scratch — useful when
    /// the computation logic has changed or a day's cache got out of
    /// sync with the raw data.
    ///
    /// Clears two classes of derived data and triggers a fresh
    /// stats rebuild from the raw EDF files:
    ///   1. `DailyStatsCache.filename` sidecars inside each day
    ///      folder — these get recomputed by the reload that
    ///      follows.
    ///   2. `IntelligenceCache.dayFilename` sidecars (per-night AI
    ///      narratives + metric-explain LRUs) and the device-level
    ///      `IntelligenceCache.deviceFilename` (Trends narratives,
    ///      Trends metric-explain LRUs). AI caches are *cleared
    ///      but not regenerated* — they rebuild lazily on demand
    ///      the next time the user opens a Sleep Analysis / Explain
    ///      surface.
    ///
    /// **User-authored notes (`DailyNotesCache.filename`,
    /// `DeviceNotesCache.filename`) are never touched** — they
    /// aren't derived data and can't be recomputed.
    func rebuildCache() {
        guard let url = card?.rootURL else { return }
        let datalog = url.appendingPathComponent("DATALOG", isDirectory: true)
        let fm = FileManager.default
        if let dayDirs = try? fm.contentsOfDirectory(
            at: datalog,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for dir in dayDirs {
                try? fm.removeItem(at: dir.appendingPathComponent(DailyStatsCache.filename))
                try? fm.removeItem(at: dir.appendingPathComponent(IntelligenceCache.dayFilename))
                // Sleep-stage sidecars are derived data from
                // HealthKit, so the rebuild path drops them too.
                // The next attach() will re-fetch from HealthKit
                // when the user has the toggle on.
                try? fm.removeItem(at: dir.appendingPathComponent(SleepStageCache.filename))
            }
        }
        // Device-level intelligence sidecar (Trends narratives +
        // Trends metric-explain LRUs) lives at the device root,
        // not inside DATALOG.
        try? fm.removeItem(at: url.appendingPathComponent(IntelligenceCache.deviceFilename))
        load(url)
    }

    // MARK: - Apple Watch sleep

    /// Whether the user has opted in to pulling Apple Watch sleep
    /// stages. Mirrors the `HealthKitSleepCoordinator.isEnabled`
    /// flag so views that only have `Library` can render the toggle
    /// without fishing into the coordinator.
    var appleWatchSleepEnabled: Bool {
        healthSleep.isEnabled
    }

    /// Flip the Apple Watch sleep toggle. Persists the choice to
    /// `UserDefaults` and, when enabling, triggers an authorization
    /// request followed by a backfill against the currently-loaded
    /// card. Disabling clears the in-memory map but leaves sidecars
    /// on disk so re-enabling picks up where the user left off.
    func setAppleWatchSleepEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.appleWatchSleepEnabledKey)
        healthSleep.setEnabled(enabled)
        guard enabled else { return }
        Task { [weak self] in
            await self?.healthSleep.requestAuthorization()
            if let card = self?.card {
                await self?.healthSleep.backfill(card: card)
            }
        }
    }

    /// Manually re-run the backfill — used by the Settings "Re-sync
    /// now" button when a user adds older nights from another device
    /// and wants the local app to catch up immediately.
    func resyncAppleWatchSleep() {
        guard let card else { return }
        Task { [weak self] in
            await self?.healthSleep.backfill(card: card)
        }
    }

    /// Decide whether to surface the first-launch confirmation. Only
    /// fires once per device install (gated on
    /// `appleWatchSleepPromptShownKey`) and never when the user has
    /// already enabled the feature explicitly. macOS skips it
    /// entirely — the Apple Watch sleep integration is iOS-only.
    fileprivate func maybeShowHealthKitFirstRunPrompt() {
        #if os(macOS)
        return
        #else
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.appleWatchSleepPromptShownKey),
              !defaults.bool(forKey: Self.appleWatchSleepEnabledKey) else {
            return
        }
        pendingHealthKitPrompt = true
        #endif
    }

    /// Called by `ContentView` when the user taps "Yes" on the
    /// confirmation dialog. Records the prompt as shown, flips the
    /// toggle on, and kicks off the auth+backfill sequence.
    func acceptHealthKitFirstRunPrompt() {
        UserDefaults.standard.set(true, forKey: Self.appleWatchSleepPromptShownKey)
        pendingHealthKitPrompt = false
        setAppleWatchSleepEnabled(true)
    }

    /// Called by `ContentView` when the user taps "Not now" or
    /// dismisses the dialog. Records the prompt as shown so we don't
    /// nag again on subsequent imports; the user can still flip the
    /// toggle on from Settings later.
    func declineHealthKitFirstRunPrompt() {
        UserDefaults.standard.set(true, forKey: Self.appleWatchSleepPromptShownKey)
        pendingHealthKitPrompt = false
    }

    // MARK: - Per-day notes

    /// Read the user-authored note for `day`, or `nil` when none
    /// exists / the day folder has no files to anchor a note to.
    func note(for day: ResMedDay) -> DailyNote? {
        guard let folder = day.files.first?.url.deletingLastPathComponent()
        else { return nil }
        return DailyNotesCache.load(for: folder)
    }

    /// Persist `text` as the note for `day`. A nil or whitespace-only
    /// string removes the free-form prose but preserves any user-
    /// asserted tags and rating, so clearing the editor doesn't
    /// silently wipe the user's tag/rating assertions. The sidecar
    /// is only fully deleted when text, user tags, and rating are
    /// all empty (handled by `DailyNotesCache.save`).
    ///
    /// After persisting, schedules a best-effort tag extraction pass
    /// when Apple Intelligence is available. Existing
    /// `extractedTags` are preserved when the note text hash is
    /// unchanged, so re-saving the same text doesn't churn the model.
    func setNote(_ text: String?, for day: ResMedDay) {
        guard let folder = day.files.first?.url.deletingLastPathComponent()
        else { return }
        let raw = text ?? ""
        let prior = DailyNotesCache.load(for: folder)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            pendingTagExtractions.removeValue(forKey: folder)?.cancel()
            // Preserve user-asserted tags, rating, and per-session
            // mask assignments — the user may have tagged a night
            // they never wrote about. Cancels any pending extraction
            // because the text is gone.
            DailyNotesCache.save(
                DailyNote(
                    text: "",
                    updatedAt: Date(),
                    extractedTags: nil,
                    tagsInputHash: nil,
                    taxonomyVersion: nil,
                    userTags: prior?.userTags,
                    subjectiveScore: prior?.subjectiveScore,
                    sessionMasks: prior?.sessionMasks
                ),
                to: folder
            )
            return
        }
        let newHash = IntelligenceCache.hash(of: raw)
        let reuseTags = prior?.tagsInputHash == newHash
            && prior?.taxonomyVersion == NoteTagTaxonomy.version
        DailyNotesCache.save(
            DailyNote(
                text: raw,
                updatedAt: Date(),
                extractedTags: reuseTags ? prior?.extractedTags : nil,
                tagsInputHash: reuseTags ? prior?.tagsInputHash : nil,
                taxonomyVersion: reuseTags ? prior?.taxonomyVersion : nil,
                userTags: prior?.userTags,
                subjectiveScore: prior?.subjectiveScore,
                sessionMasks: prior?.sessionMasks
            ),
            to: folder
        )
        extractTagsIfNeeded(for: folder, text: raw, hash: newHash)
    }

    /// Persist `tags` as the user-asserted tag list for `day`. `nil`
    /// clears the assertion so correlation falls back to whatever
    /// the on-device extractor produced; an empty array is a
    /// legitimate assertion ("no tags apply") and still suppresses
    /// the extracted list for downstream use.
    func setUserTags(_ tags: [NoteTag]?, for day: ResMedDay) {
        guard let folder = day.files.first?.url.deletingLastPathComponent()
        else { return }
        let prior = DailyNotesCache.load(for: folder) ?? DailyNote(text: "")
        DailyNotesCache.save(
            DailyNote(
                text: prior.text,
                updatedAt: Date(),
                extractedTags: prior.extractedTags,
                tagsInputHash: prior.tagsInputHash,
                taxonomyVersion: prior.taxonomyVersion,
                userTags: tags,
                subjectiveScore: prior.subjectiveScore,
                sessionMasks: prior.sessionMasks
            ),
            to: folder
        )
    }

    /// Persist the user's subjective 1–5 rating for `day`. `nil`
    /// clears the rating. The bounds aren't enforced here — the
    /// stored `Int` is whatever the UI supplied — but views pin the
    /// control to 1–5.
    func setSubjectiveScore(_ score: Int?, for day: ResMedDay) {
        guard let folder = day.files.first?.url.deletingLastPathComponent()
        else { return }
        let prior = DailyNotesCache.load(for: folder) ?? DailyNote(text: "")
        DailyNotesCache.save(
            DailyNote(
                text: prior.text,
                updatedAt: Date(),
                extractedTags: prior.extractedTags,
                tagsInputHash: prior.tagsInputHash,
                taxonomyVersion: prior.taxonomyVersion,
                userTags: prior.userTags,
                subjectiveScore: score,
                sessionMasks: prior.sessionMasks
            ),
            to: folder
        )
    }

    /// Seed a note sidecar with the user's import-time defaults when
    /// the day is being seen for the first time. Called from the
    /// backfill callback so freshly-imported nights land with the
    /// configured defaults already applied — manual edits on
    /// previously-seen days are never overwritten.
    ///
    /// Two independent default streams flow through here:
    /// - `defaultJournalTags`: written into `userTags` on a brand-new
    ///   sidecar.
    /// - `defaultMaskID`: stamped into `sessionMasks[sessionKey]` for
    ///   every session of the day. Stamps both on first observation
    ///   *and* on later observations of newly-rolled session keys
    ///   (e.g. an early-evening import followed by a re-import after
    ///   the second night-time session was recorded), so a fresh
    ///   session that lands inside an already-stamped day still
    ///   inherits the current default. Pre-existing assignments are
    ///   never rewritten — that's the "applies to new imports only"
    ///   guarantee.
    private func applyDefaultJournalTagsIfNeeded(for day: ResMedDay) {
        guard let folder = day.files.first?.url.deletingLastPathComponent()
        else { return }
        let prior = DailyNotesCache.load(for: folder)
        let isFreshSidecar = prior == nil
        let dayKeys = Array(Set(day.files.compactMap(\.sessionKey)))

        // Prepare the stamped mask map. Reuse whatever's on disk and
        // only insert keys we don't already have an entry for, so a
        // user picking a different mask on session N keeps it after
        // session N+1 imports the next day's default.
        var maskMap = prior?.sessionMasks ?? [:]
        var maskMapChanged = false
        if let defaultMask = defaultMaskID,
           userMasks.contains(where: { $0.id == defaultMask }) {
            let raw = defaultMask.uuidString
            for key in dayKeys where maskMap[key] == nil {
                maskMap[key] = raw
                maskMapChanged = true
            }
        }

        // Default tags only seed on a brand-new sidecar — touching an
        // existing one would clobber a manual edit.
        let shouldSeedTags = isFreshSidecar && !defaultJournalTags.isEmpty
        guard shouldSeedTags || maskMapChanged else { return }

        let userTags: [NoteTag]?
        if shouldSeedTags {
            userTags = NoteTag.allCases.filter { defaultJournalTags.contains($0) }
        } else {
            userTags = prior?.userTags
        }

        DailyNotesCache.save(
            DailyNote(
                text: prior?.text ?? "",
                updatedAt: Date(),
                extractedTags: prior?.extractedTags,
                tagsInputHash: prior?.tagsInputHash,
                taxonomyVersion: prior?.taxonomyVersion,
                userTags: userTags,
                subjectiveScore: prior?.subjectiveScore,
                sessionMasks: maskMap.isEmpty ? nil : maskMap
            ),
            to: folder
        )
    }

    /// Kick off a best-effort tag-extraction pass for a note. Bails
    /// out silently when Apple Intelligence is unavailable, when a
    /// fresh extraction for this exact text is already queued, or
    /// when the cached result is still valid.
    private func extractTagsIfNeeded(
        for folder: URL,
        text: String,
        hash: String
    ) {
        guard intelligence.isReady else { return }
        // Short-circuit when we already have tags for this text.
        if let note = DailyNotesCache.load(for: folder),
           note.tagsInputHash == hash,
           note.taxonomyVersion == NoteTagTaxonomy.version,
           note.extractedTags != nil {
            return
        }
        pendingTagExtractions[folder]?.cancel()
        let service = narration
        pendingTagExtractions[folder] = Task { @MainActor [weak self] in
            do {
                let result = try await service.extractNoteTags(
                    NoteTagInput(text: text)
                )
                guard !Task.isCancelled else { return }
                // Re-read — the user may have edited mid-flight. If
                // the current note's text no longer matches the hash
                // we generated against, discard the result so stale
                // tags don't overwrite a fresh note.
                guard let current = DailyNotesCache.load(for: folder),
                      IntelligenceCache.hash(of: current.text) == hash
                else { return }
                DailyNotesCache.save(
                    DailyNote(
                        text: current.text,
                        updatedAt: current.updatedAt,
                        extractedTags: result.tags,
                        tagsInputHash: hash,
                        taxonomyVersion: NoteTagTaxonomy.version,
                        userTags: current.userTags,
                        subjectiveScore: current.subjectiveScore,
                        sessionMasks: current.sessionMasks
                    ),
                    to: folder
                )
            } catch {
                // Best-effort — swallow failures. The next save
                // attempt will try again.
            }
            // Self-evict on natural completion so the dict doesn't
            // grow for the life of the session. Replacement calls
            // cancel the prior task first (see above), so a non-
            // cancelled end means we're still the entry at `folder`.
            if !Task.isCancelled {
                self?.pendingTagExtractions.removeValue(forKey: folder)
            }
        }
    }

    // MARK: - Intelligence helpers

    /// Fetch the on-device night summary for `day`, hitting the
    /// `.snorecard-intelligence.json` sidecar first so repeat views
    /// of the same night are instant. Returns `nil` when Apple
    /// Intelligence is unavailable or the model refuses the output.
    func nightSummary(for day: ResMedDay) async -> NightSummaryOutput? {
        guard intelligence.isReady else { return nil }
        guard let folder = day.files.first?.url.deletingLastPathComponent(),
              let stats = day.stats, stats.hasUsage else { return nil }
        let allStats = (card?.days.compactMap(\.stats) ?? []).filter(\.hasUsage)
        let excludeCentral = !includesCentralEvents
        let baseline = IntelligenceInputBuilder.Baseline.trailing14(
            before: day.date,
            from: allStats,
            excludeCentralFromAHI: excludeCentral
        )
        let note = DailyNotesCache.load(for: folder)
        let sleepSummary = healthSleep.summaryByDate[day.date]
        let input = IntelligenceInputBuilder.nightSummary(
            stats: stats,
            baseline: baseline,
            userNote: note?.text,
            subjectiveScore: note?.subjectiveScore,
            userTags: note?.effectiveTags ?? [],
            sleepSummary: sleepSummary,
            excludeCentralFromAHI: excludeCentral
        )
        let hash = IntelligenceCache.hash(of: input)
        if let cached = IntelligenceCache.loadNightSummary(
            for: folder,
            matching: hash,
            templateVersion: NightSummaryPrompt.templateVersion
        ) {
            return cached
        }
        do {
            let output = try await narration.nightSummary(input)
            IntelligenceCache.saveNightSummary(
                output,
                inputHash: hash,
                templateVersion: NightSummaryPrompt.templateVersion,
                to: folder
            )
            return output
        } catch {
            return nil
        }
    }

    /// Fetch the on-device trends narrative for a pre-filtered
    /// window. Caches keyed on the input hash so switching between
    /// preset ranges (7d / 14d / 30d) doesn't regenerate unless the
    /// underlying aggregates actually changed.
    func trendsNarrative(
        stats: [DailyStatistics],
        rangeStart: Date,
        rangeEnd: Date
    ) async -> TrendsNarrativeOutput? {
        guard intelligence.isReady else { return nil }
        guard let folder = card?.rootURL else { return nil }
        guard !stats.isEmpty else { return nil }
        // Apple Watch sleep summaries that fall inside the same
        // range — gives the narrative access to deep/core/REM
        // averages alongside the CPAP aggregates.
        let sleepSummaries = healthSleep.summaryByDate.values
            .filter { $0.nightDate >= rangeStart && $0.nightDate <= rangeEnd }
            .sorted { $0.nightDate < $1.nightDate }
        let input = IntelligenceInputBuilder.trendsNarrative(
            stats: stats,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            complianceTargetHours: complianceTarget(
                for: card?.identification?.serialNumber
            ),
            sleepSummaries: sleepSummaries,
            excludeCentralFromAHI: !includesCentralEvents
        )
        let hash = IntelligenceCache.hash(of: input)
        if let cached = IntelligenceCache.loadTrendsNarrative(
            for: folder,
            matching: hash,
            templateVersion: TrendsNarrativePrompt.templateVersion
        ) {
            return cached
        }
        do {
            let output = try await narration.trendsNarrative(input)
            IntelligenceCache.saveTrendsNarrative(
                output,
                inputHash: hash,
                templateVersion: TrendsNarrativePrompt.templateVersion,
                to: folder
            )
            return output
        } catch {
            return nil
        }
    }

    /// Explain a single metric for the selected day. `trailing`
    /// should be the recent window the caller has already filtered
    /// (typically the last 14 days with usage). Sleep-stage metrics
    /// pull their value from the watch summary instead of stats —
    /// the caller passes those in via `sleepSummary` /
    /// `trailingSleepSummaries`.
    func explainMetric(
        _ metric: ExplainableMetric,
        for day: ResMedDay,
        trailing: [DailyStatistics],
        sleepSummary: NightlySleepSummary? = nil,
        trailingSleepSummaries: [NightlySleepSummary] = []
    ) async -> MetricExplainOutput? {
        guard intelligence.isReady else { return nil }
        guard let folder = day.files.first?.url.deletingLastPathComponent(),
              let stats = day.stats else { return nil }
        let input: MetricExplainInput?
        if metric.isSleepStage {
            guard let sleepSummary else { return nil }
            input = IntelligenceInputBuilder.metricExplain(
                metric: metric,
                summary: sleepSummary,
                trailingSummaries: trailingSleepSummaries
            )
        } else {
            input = IntelligenceInputBuilder.metricExplain(
                metric: metric,
                stats: stats,
                trailing: trailing,
                excludeCentralFromAHI: !includesCentralEvents
            )
        }
        guard let input else { return nil }
        let hash = IntelligenceCache.hash(of: input)
        if let cached = IntelligenceCache.loadMetricExplain(
            for: folder,
            metric: metric,
            matching: hash,
            templateVersion: MetricExplainPrompt.templateVersion
        ) {
            return cached
        }
        do {
            let output = try await narration.explainMetric(input)
            IntelligenceCache.saveMetricExplain(
                output,
                metric: metric,
                inputHash: hash,
                templateVersion: MetricExplainPrompt.templateVersion,
                to: folder
            )
            return output
        } catch {
            return nil
        }
    }

    /// Explain a Trends-style aggregate card — the value is
    /// already a range average, so the prompt is reframed from
    /// "this night vs your recent average" to "this average vs
    /// the norms". Caches at device level, not per-day.
    func explainTrendsMetric(
        _ metric: ExplainableMetric,
        averageValue: Double,
        rangeStart: Date,
        rangeEnd: Date,
        sampleSize: Int
    ) async -> MetricExplainOutput? {
        guard intelligence.isReady else { return nil }
        guard let folder = card?.rootURL else { return nil }
        let input = IntelligenceInputBuilder.trendsMetricExplain(
            metric: metric,
            averageValue: averageValue,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            sampleSize: sampleSize,
            complianceTargetHours: complianceTarget(
                for: card?.identification?.serialNumber
            )
        )
        let hash = IntelligenceCache.hash(of: input)
        if let cached = IntelligenceCache.loadTrendsMetricExplain(
            for: folder,
            matching: hash,
            templateVersion: MetricExplainPrompt.templateVersion
        ) {
            return cached
        }
        do {
            let output = try await narration.explainMetric(input)
            IntelligenceCache.saveTrendsMetricExplain(
                output,
                inputHash: hash,
                templateVersion: MetricExplainPrompt.templateVersion,
                to: folder
            )
            return output
        } catch {
            return nil
        }
    }

    /// Resolve an `ExplainRequest` to its on-device explanation by
    /// dispatching to the per-day or Trends-scoped helper based
    /// on the request's source. Hides the day-vs-range difference
    /// from the sheet/inspector view so a single surface can
    /// render both.
    func resolveExplain(_ request: ExplainRequest) async -> MetricExplainOutput? {
        switch request.source {
        case .day(let dayID):
            guard let card,
                  let day = card.days.first(where: { $0.id == dayID })
            else { return nil }
            let calendar = Calendar.current
            guard let windowStart = calendar.date(
                byAdding: .day,
                value: -14,
                to: day.date
            ) else { return nil }
            let trailing = card.days
                .compactMap(\.stats)
                .filter { $0.hasUsage && $0.date >= windowStart && $0.date < day.date }
            // Sleep-stage explanations need the watch summary for
            // this night plus the trailing 14 days of summaries
            // for the recent-mean anchor. Both are pulled from the
            // coordinator's already-hydrated map; an empty list is
            // fine for non-sleep metrics.
            let sleepSummary = healthSleep.summaryByDate[day.date]
            let trailingSleepSummaries = healthSleep.summaryByDate.values
                .filter { $0.nightDate >= windowStart && $0.nightDate < day.date }
                .sorted { $0.nightDate < $1.nightDate }
            return await explainMetric(
                request.metric,
                for: day,
                trailing: trailing,
                sleepSummary: sleepSummary,
                trailingSleepSummaries: trailingSleepSummaries
            )
        case .trends(let averageValue, let rangeStart, let rangeEnd, let sampleSize):
            return await explainTrendsMetric(
                request.metric,
                averageValue: averageValue,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                sampleSize: sampleSize
            )
        }
    }

    /// Build the correlation observations + LLM narration for the
    /// supplied range. Returns a bundle the view can render as a
    /// single card, or `nil` when the range doesn't meet the
    /// `TagCorrelator` thresholds.
    struct CorrelationBundle {
        let observations: [CorrelationNarrativeInput.Observation]
        let narration: CorrelationNarrativeOutput
    }

    func correlationHints(
        stats: [DailyStatistics],
        rangeStart: Date,
        rangeEnd: Date
    ) async -> CorrelationBundle? {
        guard intelligence.isReady else { return nil }
        guard let card else { return nil }
        let dayInputs: [TagCorrelator.DayInput] = card.days.compactMap { day in
            guard let stat = day.stats, stat.hasUsage,
                  stat.date >= rangeStart, stat.date <= rangeEnd,
                  let folder = day.files.first?.url.deletingLastPathComponent()
            else { return nil }
            let note = DailyNotesCache.load(for: folder)
            // Prefer user-asserted tags over the extractor's guess —
            // the person reading the correlation card is the same
            // person who asserted the tags, so their labelling is
            // authoritative. Falls back to `extractedTags` when the
            // user hasn't overridden.
            let tags = note?.effectiveTags ?? []
            return TagCorrelator.DayInput(
                tags: Set(tags),
                stats: stat
            )
        }
        let observations = TagCorrelator.correlate(
            days: dayInputs,
            excludeCentralFromAHI: !includesCentralEvents
        )
        guard !observations.isEmpty else { return nil }
        let truncated = Array(observations.prefix(6))
        let input = CorrelationNarrativeInput(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            sampleSize: dayInputs.count,
            observations: truncated
        )
        do {
            let output = try await narration.correlationNarrative(input)
            return CorrelationBundle(observations: truncated, narration: output)
        } catch {
            return nil
        }
    }

    // MARK: - Per-device notes

    /// Read the device-wide "overall" note for the currently-loaded
    /// card, or `nil` when no card is loaded / no note has been
    /// authored yet. The sidecar lives at the root of the device
    /// folder (next to `DATALOG/`).
    func deviceNote() -> DeviceNote? {
        guard let folder = card?.rootURL else { return nil }
        return DeviceNotesCache.load(for: folder)
    }

    /// Persist `text` as the device-wide note for the currently-loaded
    /// card. A nil or whitespace-only string removes the note
    /// entirely. Mirrors `setNote(_:for:)` — same blank-means-delete
    /// cleanup, same `updatedAt` stamping.
    func setDeviceNote(_ text: String?) {
        guard let folder = card?.rootURL else { return }
        let raw = text ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DeviceNotesCache.save(nil, to: folder)
        } else {
            DeviceNotesCache.save(
                DeviceNote(text: raw, updatedAt: Date()),
                to: folder
            )
        }
    }

    /// Auto-load data on launch. Tries to re-open the device the user
    /// last actively selected (persisted in iCloud KVS so it follows
    /// the user across Macs and iPhones). Falls back to the most
    /// recently modified iCloud folder, and finally to whatever was
    /// last opened locally.
    func loadLastOpenedIfPossible() async {
        guard case .empty = state else {
            isInitialProbing = false
            return
        }
        // Make sure the probe flag is cleared no matter which arm
        // of the logic below runs.
        defer { isInitialProbing = false }

        // Fast path — an iCloud folder is already visible locally.
        if let url = Self.preferredICloudDeviceFolder() {
            let serial = url.lastPathComponent
            if let snapshot = CardSnapshot.load(forSerial: serial) {
                state = .hydrating(snapshot)
            }
            load(url)
            return
        }

        // Fresh-install rescue. On a brand-new iPad/iPhone the
        // iCloud container's backup root may not have been
        // materialized locally yet, so `iCloudDeviceFolders()`
        // returns empty even though the source device's data is
        // already in the account. Poll for a few seconds while the
        // UI shows an "Opening Snorecard…" splash, then fall
        // through to the UserDefaults fallback if nothing surfaces.
        //
        // 6 × 500 ms = 3 s, enough to cover the common "iCloud just
        // hasn't indexed yet" case without making a genuinely empty
        // install wait forever.
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let url = Self.preferredICloudDeviceFolder() {
                let serial = url.lastPathComponent
                if let snapshot = CardSnapshot.load(forSerial: serial) {
                    state = .hydrating(snapshot)
                }
                load(url)
                return
            }
        }

        // Last resort — whatever path we stashed in UserDefaults
        // (used when iCloud is entirely unavailable).
        guard
            let path = UserDefaults.standard.string(forKey: Self.lastPathKey),
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else { return }
        load(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Pick the device folder to auto-load on launch. First priority
    /// is the serial the user last explicitly opened (synced via
    /// `NSUbiquitousKeyValueStore` so the choice persists between
    /// devices). If that serial's folder isn't here yet, fall back to
    /// the most recently modified folder.
    private static func preferredICloudDeviceFolder() -> URL? {
        let folders = iCloudDeviceFolders()
        guard !folders.isEmpty else { return nil }

        let kvs = NSUbiquitousKeyValueStore.default
        if let wanted = kvs.string(forKey: lastOpenedSerialKey),
           let match = folders.first(where: { $0.serial == wanted }) {
            return match.url
        }
        return folders.first?.url
    }

    /// Record a device's serial as the most recently opened one.
    /// Syncs via iCloud KVS so every device remembers the last
    /// selection across launches.
    fileprivate func rememberLastOpened(serial: String?) {
        let kvs = NSUbiquitousKeyValueStore.default
        if let serial, !serial.isEmpty {
            kvs.set(serial, forKey: Self.lastOpenedSerialKey)
        } else {
            kvs.removeObject(forKey: Self.lastOpenedSerialKey)
        }
        kvs.synchronize()
    }

    /// Summary of a device folder stored inside Snorecard's iCloud
    /// container. Presented to the user in the sidebar switcher so they
    /// can pick between machines without re-importing.
    struct DeviceFolder: Identifiable, Hashable, Sendable {
        let url: URL
        let serial: String
        /// Product name pulled from the folder's `Identification` file
        /// (e.g. "AirSense 10 AutoSet"). `nil` when the file is missing
        /// or can't be parsed.
        let productName: String?
        let modified: Date?
        var id: URL { url }
    }

    /// Every device folder inside the iCloud backup root, sorted most-
    /// recently-modified first. Empty when iCloud is unavailable.
    static func iCloudDeviceFolders() -> [DeviceFolder] {
        guard let backupRoot = iCloudBackupRoot else { return [] }
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupRoot.path) else { return [] }

        let subfolders = ((try? fm.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            // The Backups/ sibling holds `.aar` archives, not raw
            // device data. Skip it so restored archives don't get
            // mistaken for a separate device.
            guard url.lastPathComponent != Self.backupsFolderName else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        return subfolders
            .map { url -> DeviceFolder in
                let productName: String? = {
                    guard let idURL = ResMedIdentification.locate(in: url),
                          let ident = try? ResMedIdentification(contentsOf: idURL)
                    else { return nil }
                    return ident.productName
                }()
                return DeviceFolder(
                    url: url,
                    serial: url.lastPathComponent,
                    productName: productName,
                    modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                )
            }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    func load(_ url: URL) {
        // If the sidebar already shows the device being loaded (via
        // a snapshot-seeded `.hydrating` state, or a prior `.loaded`
        // card being refreshed) preserve the visible day list so the
        // user doesn't get flashed a loading screen.
        let existingCard: ResMedSDCard? = {
            switch state {
            case .hydrating(let c), .loaded(let c): return c
            default: return nil
            }
        }()
        let preserveHydration: Bool = {
            guard let existing = existingCard else { return false }
            if existing.rootURL == url { return true }
            if existing.identification?.serialNumber == url.lastPathComponent {
                return true
            }
            return false
        }()

        if preserveHydration, let existing = existingCard {
            // Keep what the user sees on screen as the hydrating card
            // while we kick off a fresh scan in the background.
            state = .hydrating(existing)
        } else {
            state = .loading(url)
            #if os(iOS)
            // On iPhone NavigationSplitView is a stack — clear the
            // selection immediately so the detail pane pops back to
            // the sidebar instead of leaving the user stuck on a now-
            // stale Trends / Day view while the new device loads.
            selection = nil
            #endif
        }
        cloudPrefetchProgress = nil

        let source = CardSource.detect(from: url)
        Task.detached { [weak self] in
            // Re-arm security-scoped access for SD-card imports
            // inside the detached task. On iOS the URL comes from
            // UIDocumentPicker and needs an explicit
            // start/stop pair — the picker's start in the
            // delegate doesn't always propagate to a detached
            // task, and without it the merge's
            // `fm.contentsOfDirectory` throws and the whole
            // import silently falls back to the SD-only path.
            // No-op on iCloud URLs (returns false; the defer
            // skips stop).
            let didAccess = source == .sdCard
                ? url.startAccessingSecurityScopedResource()
                : false
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            // Eagerly download iCloud sidecar placeholders so the
            // scan hits its cache path for every day.
            if source == .iCloud {
                await CloudPrefetcher.prefetchSidecars(in: url) { progress in
                    await MainActor.run {
                        // Hide the indicator once everything has
                        // finished; keep it visible while downloading.
                        self?.cloudPrefetchProgress = progress.completed < progress.total
                            ? progress
                            : nil
                    }
                }
                await MainActor.run { self?.cloudPrefetchProgress = nil }
            }

            do {
                // Phase 1 — quick structure-only scan. Gives us the
                // day list and any sidecar-cached stats immediately.
                var structure = try SDCardImporter.scanStructure(url)

                // Fresh-install rescue. On a brand-new iPad/iPhone,
                // iCloud often surfaces the device folder before its
                // DATALOG subfolders — `scanStructure` returns zero
                // days even though the source device's data is
                // already in the container. Ask iCloud to materialize
                // the tree (queries for *.edf and triggers their
                // download, which pulls day-folder metadata with
                // them), wait briefly for directory listings to
                // populate, and re-scan. A few short passes give
                // iCloud time to deliver the metadata without
                // pushing the user into a multi-minute wall of
                // nothing.
                if source == .iCloud && structure.days.isEmpty {
                    for attempt in 0..<3 where structure.days.isEmpty {
                        await CloudPrefetcher.materializeDeviceTree(in: url)
                        // Linear backoff — 1 s, 2 s, 3 s. Bigger
                        // than 500 ms polls because iCloud metadata
                        // updates land on their own cadence, and
                        // smaller intervals just churn.
                        try? await Task.sleep(
                            nanoseconds: UInt64(attempt + 1) * 1_000_000_000
                        )
                        if let rescan = try? SDCardImporter.scanStructure(url) {
                            structure = rescan
                        }
                    }
                }

                // For SD card imports, merge new day folders into
                // iCloud first, then use the iCloud folder as the
                // canonical source so history accumulates there.
                var currentCard = structure
                var currentURL = url
                if source == .sdCard {
                    if let iCloudURL = await Self.mergeIntoICloud(
                        sourceURL: url,
                        card: structure
                    ) {
                        // Prefetch iCloud's view of this device so
                        // the re-scan sees every historical day, not
                        // just the ones we just copied off the SD.
                        // Critical on iPhone first-run imports where
                        // iOS hasn't materialized the device folder
                        // at all yet.
                        await CloudPrefetcher.prefetchSidecars(in: iCloudURL) { progress in
                            await MainActor.run {
                                self?.cloudPrefetchProgress = progress.completed < progress.total
                                    ? progress
                                    : nil
                            }
                        }
                        await MainActor.run { self?.cloudPrefetchProgress = nil }

                        if let merged = try? SDCardImporter.scanStructure(iCloudURL) {
                            currentCard = merged
                            currentURL = iCloudURL
                        }
                    }
                }

                // Publish the structure so the sidebar renders now,
                // before the aggregate backfill starts chewing EDFs.
                // Also apply the user's per-session exclusions to any
                // sidecar-cached days that came back from the
                // structure scan with stats already populated, so the
                // sidebar's first paint reflects the same totals as
                // the day view.
                let productName = currentCard.identification?.productName
                let baseCard = currentCard
                let exclusionsForSeed: Set<String> = await MainActor.run {
                    self?.excludedSessionKeys ?? []
                }
                if !exclusionsForSeed.isEmpty {
                    let filteredDays: [ResMedDay] = baseCard.days.map { day in
                        let dayKeys = day.files.compactMap(\.sessionKey)
                        guard exclusionsForSeed.contains(where: dayKeys.contains) else {
                            return day
                        }
                        let recomputed = DailyStatistics.aggregate(
                            for: day,
                            productName: productName,
                            excluding: exclusionsForSeed
                        )
                        return ResMedDay(date: day.date, files: day.files, stats: recomputed)
                    }
                    currentCard = ResMedSDCard(
                        rootURL: baseCard.rootURL,
                        identification: baseCard.identification,
                        summaryFileURL: baseCard.summaryFileURL,
                        days: filteredDays
                    )
                }
                let seededCard = currentCard
                let persistedPath = currentURL.path
                let loadedSerial = seededCard.identification?.serialNumber
                await MainActor.run {
                    UserDefaults.standard.set(persistedPath, forKey: Self.lastPathKey)
                    self?.rememberLastOpened(serial: loadedSerial)
                    self?.state = .hydrating(seededCard)
                }

                // Phase 2 — stream per-day aggregates. Each callback
                // replaces one day's stats in place; the accumulated
                // card is the new canonical value until the final
                // `.loaded` transition below.
                nonisolated(unsafe) var accumulated = seededCard
                await SDCardImporter.backfillStats(
                    for: seededCard,
                    productName: productName
                ) { @MainActor [weak self] updatedDay in
                    let dayToStore = self?.applyingExclusions(
                        to: updatedDay,
                        productName: productName
                    ) ?? updatedDay
                    accumulated = accumulated.replacing(day: dayToStore)
                    self?.applyDefaultJournalTagsIfNeeded(for: updatedDay)
                    // Keep publishing as `.hydrating` — the final
                    // `.loaded` transition runs once the group finishes.
                    self?.state = .hydrating(accumulated)
                }

                let finalCard = accumulated
                await MainActor.run {
                    self?.state = .loaded(finalCard)
                    // Persist snapshot so the next launch can paint
                    // the sidebar before any I/O completes.
                    CardSnapshot.save(finalCard)
                    self?.applyDefaultSelection(for: finalCard)
                }
                // Hydrate the sleep-stage map from on-disk sidecars
                // and, if the user has opted in and HealthKit is
                // ready, run the single-batched backfill for any
                // missing/stale nights. Runs after `.loaded` so the
                // sleep card on the day view appears as soon as the
                // sidecars finish loading.
                //
                // macOS runs this too — the coordinator's `attach`
                // disk-hydrates first and bails before any HealthKit
                // call when `isEnabled == false`, which it always
                // is on macOS. That gives Mac a read-only view of
                // whatever the iPhone wrote to iCloud Drive without
                // touching the (unreliable) macOS HealthKit store.
                // `maybeShowHealthKitFirstRunPrompt` is also a
                // no-op on macOS by its own internal guard.
                await self?.healthSleep.attach(card: finalCard)
                await MainActor.run {
                    self?.maybeShowHealthKitFirstRunPrompt()
                }
            } catch {
                await MainActor.run {
                    self?.state = .failed(String(describing: error))
                }
            }
        }
    }

    /// Choose the detail-pane selection after a card finishes loading.
    /// On iOS we stay on the sidebar; on macOS we default to Trends
    /// (or the most recent day with raw files if STR.edf is empty).
    private func applyDefaultSelection(for card: ResMedSDCard) {
        #if os(iOS)
        // iOS NavigationSplitView is a stack — leaving selection nil
        // drops the user back on the sidebar rather than a stale
        // detail pane. Only clear if we weren't mid-drill-down via
        // the snapshot-hydration flow.
        if selection == nil { return }
        if case .day(let id) = selection,
           card.days.contains(where: { $0.id == id }) {
            return
        }
        selection = nil
        #else
        // macOS keeps the sidebar visible, so pre-select something
        // sensible — but don't override a selection the user already
        // made while the `.hydrating` state was up.
        if selection != nil { return }
        if card.days.contains(where: { $0.stats?.hasUsage == true }) {
            selection = .trends
        } else if let fallback = card.days.last(where: { !$0.files.isEmpty })?.id {
            selection = .day(fallback)
        } else {
            selection = nil
        }
        #endif
    }

    // MARK: - iCloud sync

    /// Merge a newly-imported SD card into Snorecard's iCloud ubiquity
    /// container. Day folders already present in iCloud are preserved
    /// so repeat imports accumulate history; top-level summary files
    /// (STR.edf, Identification.tgt, SETTINGS) are always refreshed.
    /// Returns the iCloud device-folder URL on success so the caller
    /// can re-scan it and present the combined dataset.
    private static func mergeIntoICloud(
        sourceURL: URL,
        card: ResMedSDCard
    ) async -> URL? {
        guard let backupRoot = iCloudBackupRoot else {
            importLog.error("mergeIntoICloud: iCloud backup root unavailable")
            return nil
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        } catch {
            importLog.error("mergeIntoICloud: failed to create backup root: \(String(describing: error), privacy: .public)")
            return nil
        }

        let deviceFolder = backupRoot.appendingPathComponent(
            Self.iCloudDeviceFolderName(for: card),
            isDirectory: true
        )
        importLog.info("mergeIntoICloud: source=\(sourceURL.path, privacy: .public) dest=\(deviceFolder.path, privacy: .public)")

        // Inlined into the caller's task — the previous nested
        // `Task.detached` lost the security-scoped resource
        // access on iOS, which made every read of `sourceURL`
        // throw a permission error and the merge silently
        // returned nil. The outer caller (`Library.load`)
        // already runs in a detached task, so we don't need a
        // second one here.
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        importLog.debug("mergeIntoICloud: didAccess=\(didAccess)")

        if !fm.fileExists(atPath: deviceFolder.path) {
            do {
                try fm.createDirectory(
                    at: deviceFolder,
                    withIntermediateDirectories: true
                )
            } catch {
                importLog.error("mergeIntoICloud: failed to create device folder: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        // SD cards mounted via the Files app on iOS surface through
        // userfsd / LiveFiles. POSIX enumeration of the volume *root*
        // (`fm.contentsOfDirectory(at: sourceURL, …)`) fails with
        // EINVAL on those paths — the mount point itself isn't a
        // regular directory the file provider will list. Subfolders
        // built with `appendingPathComponent` (e.g. `DATALOG/`) work
        // because they hit the file provider's per-item read path,
        // which is also why `SDCardImporter.scanStructure` succeeds.
        //
        // Workaround: skip the root enumeration entirely and probe
        // for the small, well-known set of top-level entries a ResMed
        // card writes. Anything missing is silently skipped.
        let knownTopLevel = [
            "DATALOG",
            "STR.edf",
            "STR.crc",
            "Identification.tgt",
            "Identification.crc",
            "Identification.json",
            "SETTINGS"
        ]

        // DATALOG day-folder copy — same logic as before.
        let datalogSrc = sourceURL.appendingPathComponent("DATALOG", isDirectory: true)
        let datalogDst = deviceFolder.appendingPathComponent("DATALOG", isDirectory: true)
        if fm.fileExists(atPath: datalogSrc.path) {
            if !fm.fileExists(atPath: datalogDst.path) {
                try? fm.createDirectory(at: datalogDst, withIntermediateDirectories: true)
            }
            let dayDirs = (try? fm.contentsOfDirectory(
                at: datalogSrc,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            importLog.info("mergeIntoICloud: DATALOG has \(dayDirs.count) day folders")
            var copiedCount = 0
            var skippedCount = 0
            for dayDir in dayDirs {
                let dayDest = datalogDst.appendingPathComponent(dayDir.lastPathComponent)
                if fm.fileExists(atPath: dayDest.path) {
                    // A prior partial sync can leave an empty day
                    // folder in iCloud. Treat those as missing so the
                    // SD card's fresh copy actually lands, instead of
                    // short-circuiting the merge on existence alone.
                    let existing = (try? fm.contentsOfDirectory(
                        at: dayDest,
                        includingPropertiesForKeys: nil,
                        options: []
                    )) ?? []
                    if !existing.isEmpty {
                        skippedCount += 1
                        continue
                    }
                    try? fm.removeItem(at: dayDest)
                }
                do {
                    try fm.copyItem(at: dayDir, to: dayDest)
                    copiedCount += 1
                } catch {
                    importLog.error("mergeIntoICloud: failed to copy \(dayDir.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            importLog.info("mergeIntoICloud: DATALOG copied=\(copiedCount) skipped=\(skippedCount)")
        } else {
            importLog.error("mergeIntoICloud: DATALOG missing at source")
            return nil
        }

        // Top-level non-DATALOG files / folders — overwrite-on-copy so
        // the latest STR.edf and Identification files supersede what
        // we already have in iCloud.
        for name in knownTopLevel where name != "DATALOG" {
            let src = sourceURL.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = deviceFolder.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                importLog.error("mergeIntoICloud: failed to copy \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        importLog.info("mergeIntoICloud: success")
        return deviceFolder
    }

    // MARK: - iCloud paths

    /// Bundle identifier for the shared Snorecard ubiquity container —
    /// declared in each target's `.entitlements` file and referenced by
    /// the ubiquity-container APIs below.
    static let iCloudContainerID = "iCloud.com.vmstan.Snorecard"

    /// On-disk URL of Snorecard's user-visible `Documents/` folder inside
    /// its iCloud ubiquity container, or `nil` when iCloud Drive isn't
    /// set up on this device. Because the container is declared as
    /// document-scope public in Info.plist, this folder shows up in
    /// Files / Finder under **iCloud Drive > Snorecard**.
    static var iCloudDriveRoot: URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: iCloudContainerID)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Where per-device syncs live inside the ubiquity container.
    static var iCloudBackupRoot: URL? {
        iCloudDriveRoot
    }

    /// Folder name for iCloud Drive syncs — keyed on serial only so a
    /// given device has exactly one folder that mirrors its current SD card.
    /// Falls back to `Unknown Device` when the SD card has no serial
    /// or the serial is unsafe for a single path component.
    private static func iCloudDeviceFolderName(for card: ResMedSDCard) -> String {
        ResMedIdentification.sanitizedSerial(card.identification?.serialNumber)
            ?? "Unknown Device"
    }

    // MARK: - Backups

    /// Subfolder name under `iCloudDriveRoot` that holds `.aar`
    /// backup archives, one per backup event. Excluded from
    /// `iCloudDeviceFolders` so archives never masquerade as
    /// devices.
    static let backupsFolderName = "Backups"

    /// Metadata about a single backup file discovered in iCloud.
    /// Presented in the Restore sheet.
    struct BackupFile: Identifiable, Hashable, Sendable {
        let url: URL
        /// Device serial this backup was taken from (the filename's
        /// leading segment). Used to group backups per device.
        let serial: String
        /// Moment the backup was written, parsed from the filename
        /// or falling back to the file's modification date.
        let createdAt: Date
        /// Size in bytes on disk.
        let byteSize: Int
        var id: URL { url }
    }

    enum BackupError: Error, CustomStringConvertible {
        case noCard
        case noCloudContainer
        case untrustedBackup

        var description: String {
            switch self {
            case .noCard:
                return "No machine is loaded. Open one before backing up."
            case .noCloudContainer:
                return "iCloud Drive is unavailable on this device."
            case .untrustedBackup:
                return "This backup's filename is malformed and can't be restored safely."
            }
        }
    }

    /// Directory under iCloud Drive where archives live. Created on
    /// first backup. `nil` if iCloud isn't configured.
    static var backupsDirectory: URL? {
        iCloudDriveRoot?.appendingPathComponent(backupsFolderName, isDirectory: true)
    }

    /// Archive the currently-loaded device's folder into the
    /// Backups directory and return the resulting file URL. Runs
    /// compression on a detached task so the main actor stays
    /// responsive — the method is async and intended to be awaited
    /// from a Task wrapping user-visible progress UI.
    func createBackup() async throws -> BackupFile {
        guard let card else { throw BackupError.noCard }
        guard let backupsDir = Self.backupsDirectory else {
            throw BackupError.noCloudContainer
        }

        let fm = FileManager.default
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let serial = ResMedIdentification.sanitizedSerial(
            card.identification?.serialNumber
        ) ?? "Unknown"
        let stamp = Self.backupFilenameFormatter.string(from: Date())
        let filename = "\(serial)-\(stamp).aar"
        let destination = backupsDir.appendingPathComponent(filename)
        let sourceURL = card.rootURL

        try await Task.detached(priority: .userInitiated) {
            try DeviceArchive.compress(directory: sourceURL, to: destination)
        }.value

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey])
            .fileSize) ?? 0
        return BackupFile(
            url: destination,
            serial: serial,
            createdAt: Date(),
            byteSize: size
        )
    }

    /// Every backup we can find on disk, newest first. If `serial`
    /// is supplied, the list is filtered to archives whose filename
    /// starts with that serial — the common "backups for the
    /// currently-loaded device" case.
    static func listBackups(forSerial serial: String? = nil) -> [BackupFile] {
        guard let dir = backupsDirectory else { return [] }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        let contents = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "aar" }
            .compactMap { url -> BackupFile? in
                let name = url.deletingPathExtension().lastPathComponent
                // Expected form: "<serial>-<yyyy-MM-dd-HHmmss>".
                // Fallback: derive serial from leading segment and
                // created-date from mtime when the stamp is
                // unparseable.
                let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                let rawSerial = parts.first.map(String.init) ?? name
                // Drop any archive whose filename can't yield a
                // serial safe to feed back into path construction
                // (e.g. one containing `..`). Without this, the
                // Restore flow could be tricked into writing outside
                // the iCloud backup root.
                guard let parsedSerial = ResMedIdentification.sanitizedSerial(rawSerial),
                      parsedSerial == rawSerial
                else { return nil }
                if let requested = serial, requested != parsedSerial {
                    return nil
                }
                let parsedDate: Date? = parts.count == 2
                    ? parseBackupStamp(String(parts[1]))
                    : nil
                let mtime = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate)
                let size = (try? url.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize) ?? 0
                return BackupFile(
                    url: url,
                    serial: parsedSerial,
                    createdAt: parsedDate ?? mtime ?? Date.distantPast,
                    byteSize: size
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Restore a backup over the top of the matching device folder,
    /// atomically swapping the old tree out for the archive's
    /// contents. The previous tree is moved aside first so a
    /// mid-flight error doesn't leave the user with a half-restored
    /// folder — on success the set-aside tree is deleted; on
    /// failure it's put back.
    func restoreBackup(_ backup: BackupFile) async throws {
        guard let root = Self.iCloudBackupRoot else {
            throw BackupError.noCloudContainer
        }
        // Defence in depth: `listBackups` already filters to safe
        // serials, but the BackupFile type itself doesn't enforce
        // it. Re-validate here so `appendingPathComponent` below
        // can't be coerced into resolving outside `root` by a
        // handcrafted BackupFile.
        guard let safeSerial = ResMedIdentification.sanitizedSerial(backup.serial),
              safeSerial == backup.serial
        else {
            throw BackupError.untrustedBackup
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let deviceURL = root.appendingPathComponent(safeSerial, isDirectory: true)
        let sidelineURL = root.appendingPathComponent(
            ".restore-old-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingURL = fm.temporaryDirectory.appendingPathComponent(
            "snorecard-restore-\(UUID().uuidString)",
            isDirectory: true
        )

        let backupURL = backup.url
        try await Task.detached(priority: .userInitiated) {
            try DeviceArchive.decompress(archive: backupURL, into: stagingURL)
        }.value

        // Swap: move current device folder aside (if any), then
        // move the staged extraction into its place.
        let hadExistingFolder = fm.fileExists(atPath: deviceURL.path)
        if hadExistingFolder {
            try fm.moveItem(at: deviceURL, to: sidelineURL)
        }
        do {
            try fm.moveItem(at: stagingURL, to: deviceURL)
        } catch {
            // Roll back — put the original folder back so the user
            // isn't left with nothing after a failed restore.
            if hadExistingFolder {
                try? fm.moveItem(at: sidelineURL, to: deviceURL)
            }
            throw error
        }

        // Clean up the side-lined copy and any lingering cached
        // sidecars so the newly-restored tree is decoded from
        // scratch.
        if hadExistingFolder {
            try? fm.removeItem(at: sidelineURL)
        }

        // Reload the newly-restored folder.
        load(deviceURL)
    }

    /// Delete a backup archive. Used by the Restore sheet's row-
    /// level delete action.
    func deleteBackup(_ backup: BackupFile) {
        try? FileManager.default.removeItem(at: backup.url)
    }

    /// UTC formatter used to *write* new backup filename stamps. The
    /// trailing `Z` marks the value as UTC so readers on any device
    /// parse back to the instant the archive was created, regardless
    /// of the local time zone either side of the transfer.
    private static let backupFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss'Z'"
        return formatter
    }()

    /// Legacy filename stamps (pre-UTC fix) were written in the
    /// author's local time zone with no suffix. We still need to
    /// render something sensible for those archives when they roam
    /// between devices — parsing them as `TimeZone.current` matches
    /// the old behaviour and avoids shifting any backup's displayed
    /// `createdAt` compared to prior builds.
    private static let legacyBackupFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// Try the UTC form first, then fall back to the legacy local-TZ
    /// form. New archives all use UTC, so the legacy branch is only
    /// exercised for filenames written by builds that predate the
    /// time-zone fix.
    private static func parseBackupStamp(_ stamp: String) -> Date? {
        if let date = backupFilenameFormatter.date(from: stamp) {
            return date
        }
        return legacyBackupFilenameFormatter.date(from: stamp)
    }
}

extension Library {
    /// Convenience alias for `showsCentralEvents` — keeps call
    /// sites readable when the bool is consumed as a "should I
    /// include this in the calculation" question.
    var includesCentralEvents: Bool {
        showsCentralEvents
    }

    /// AHI as it should appear in the UI for this library's
    /// preference. Convenience wrapper around
    /// `DailyStatistics.displayedAHI(includingCentral:)` so view code
    /// reads as `library.displayedAHI(stats)` instead of having to
    /// thread the bool through itself.
    func displayedAHI(_ stats: DailyStatistics) -> Double {
        stats.displayedAHI(includingCentral: includesCentralEvents)
    }

    /// CA index for the stacked-bar denominator. Zero when CA is
    /// hidden so the segment drops cleanly without a separate guard.
    func displayedCentralApneaIndex(_ stats: DailyStatistics) -> Double {
        stats.displayedCentralApneaIndex(visible: includesCentralEvents)
    }

    /// Time-in-apnea seconds threaded through the user's CA-display
    /// preference, so the daily Time-in-Apnea card and the Trends
    /// chart subtract central-apnea durations whenever
    /// `showsCentralEvents` is off. Returns `nil` when no EVE files
    /// were readable.
    func displayedTimeInApneaSeconds(_ stats: DailyStatistics) -> Double? {
        stats.displayedTimeInApneaSeconds(includingCentral: includesCentralEvents)
    }

    /// Whether a single CPAP session has been excluded from its day's
    /// aggregate. `sessionKey` is the `YYYYMMDD_HHMMSS` filename prefix
    /// shared by the session's BRP / EVE / PLD trio (see
    /// `ResMedDataFile.sessionKey`).
    func isSessionExcluded(_ sessionKey: String) -> Bool {
        excludedSessionKeys.contains(sessionKey)
    }

    /// Toggle a single session's exclusion and immediately re-aggregate
    /// the affected day so the sidebar / day view / trends reflect the
    /// new totals without waiting for a reload. The disk cache stays
    /// untouched — exclusions are a display-time projection layered
    /// over the canonical aggregate. `forDate` is the day the session
    /// belongs to; pass `bundle.dayStart`-derived midnight when calling
    /// from a timeline view that doesn't have a `ResMedDay` in hand.
    func toggleSessionExclusion(_ sessionKey: String, forDate date: Date) {
        if excludedSessionKeys.contains(sessionKey) {
            excludedSessionKeys.remove(sessionKey)
        } else {
            excludedSessionKeys.insert(sessionKey)
        }
        refreshDayStats(forDate: date)
    }

    /// Re-run the aggregate pass for one date with the current
    /// exclusion set applied, then publish the updated card so views
    /// observing `state` re-render. No-op when no card is loaded or
    /// the date isn't known to the current card.
    func refreshDayStats(forDate date: Date) {
        guard let card = card,
              let dayIdx = card.days.firstIndex(where: { $0.date == date }) else {
            return
        }
        let day = card.days[dayIdx]
        let exclusions = excludedSessionKeys
        let productName = card.identification?.productName
        let recomputed: DailyStatistics?
        if exclusions.isEmpty {
            // Fall back to the unfiltered cache so the user sees the
            // canonical numbers immediately on the way back to "include
            // everything."
            let dir = day.files.first?.url.deletingLastPathComponent()
            if let dir,
               let cached = DailyStatsCache.loadAnyStats(for: dir) {
                recomputed = cached
            } else {
                recomputed = DailyStatistics.aggregate(
                    for: day,
                    productName: productName
                )
            }
        } else {
            recomputed = DailyStatistics.aggregate(
                for: day,
                productName: productName,
                excluding: exclusions
            )
        }
        let updatedDay = ResMedDay(date: day.date, files: day.files, stats: recomputed)
        publish(card: card.replacing(day: updatedDay))
    }

    /// Republish the in-memory card after a per-day mutation. Mirrors
    /// the load-path's `state = .loaded(...)` so the same observers
    /// fire whether the change came from a fresh import or from a
    /// per-session exclusion toggle.
    fileprivate func publish(card: ResMedSDCard) {
        switch state {
        case .loading, .empty, .failed:
            return
        case .hydrating:
            state = .hydrating(card)
        case .loaded:
            state = .loaded(card)
        }
    }

    /// Re-aggregate `day` with the current exclusion set if any of its
    /// sessions are excluded; otherwise return it unchanged. The
    /// caller doesn't need to know whether a recompute was necessary,
    /// so the load path can pipe every day through this and pay the
    /// cost only on the days that need it.
    func applyingExclusions(
        to day: ResMedDay,
        productName: String?
    ) -> ResMedDay {
        guard !excludedSessionKeys.isEmpty else { return day }
        let dayKeys = day.files.compactMap(\.sessionKey)
        guard excludedSessionKeys.contains(where: dayKeys.contains) else {
            return day
        }
        let recomputed = DailyStatistics.aggregate(
            for: day,
            productName: productName,
            excluding: excludedSessionKeys
        )
        return ResMedDay(date: day.date, files: day.files, stats: recomputed)
    }
}
