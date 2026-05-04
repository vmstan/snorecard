import SwiftUI
import SnorecardKit

/// Sliding inspector on the daily view that shows the CPAP
/// device's settings active for that night — decoded from
/// `STR.edf`. Matches the layout / style of the Rename Device
/// sheet (grouped Form, labeled rows) so the app has one
/// consistent surface for structured data.
struct DailySettingsInspector: View {
    let settings: DeviceSettings?
    @Environment(\.dismiss) private var dismiss
    /// The night the shown settings apply to. Drives the big
    /// title in the inspector pane / sheet header row.
    var date: Date? = nil
    /// Product name pulled from `Identification.tgt/json`.
    /// Surfaced in the Device section at the top of the sheet so
    /// the reader can see which machine wrote these settings.
    var productName: String? = nil
    /// Device serial (from `Identification.tgt/json`). Surfaced in
    /// the Device section; rendered monospace so long numeric
    /// serials stay columnar with the other rows.
    var serialNumber: String? = nil
    /// User-set alias, if any — the "friendly name" the user
    /// applied via Rename Device. Shown under the Device row so
    /// the manufacturer / product / alias / serial stack reads
    /// in descending specificity.
    var deviceAlias: String? = nil
    /// Resolved device-type label ("CPAP", "APAP", "BiPAP", "ASV")
    /// used in the empty-state copy when neither alias nor product
    /// name is known. Resolved by the caller from `Library` so this
    /// view stays Library-agnostic.
    var deviceType: String? = nil

    var body: some View {
        #if os(iOS)
        // Fresh NavigationStack so this sheet's own toolbar /
        // dismiss don't bleed up into the day-detail header.
        // The `InspectorPaneHeader` at the top of `content`
        // already shows the pane label and date, so we skip
        // `.navigationTitle` on iOS.
        NavigationStack {
            content
                .padding(.top, 12)
                .navigationBarTitleDisplayMode(.inline)
        }
        #else
        content
            .navigationTitle("Therapy Details")
        #endif
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let date {
                // Match the 16pt inset used by `NotesCard` /
                // `NightSummaryCard` so the Therapy Details header
                // lines up with the other daily-inspector panes
                // when the user flips between them. The Form below
                // keeps its natural edge-to-edge grouped layout,
                // so only the header gets padded here.
                InspectorPaneHeader(
                    title: "Therapy Details",
                    caption: date.formatted(.dateTime.weekday(.wide).day().month(.wide))
                )
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
            if let settings, settings.hasAnyValue {
                settingsForm(for: settings)
            } else {
                ContentUnavailableView {
                    Label("Therapy Details Unavailable", systemImage: "fan")
                } description: {
                    Text("Your \(friendlyDeviceName) only keeps therapy settings for a rolling window of recent nights. This night sits outside that window.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Form

    @ViewBuilder
    private func settingsForm(for s: DeviceSettings) -> some View {
        Form {
            if hasDeviceIdentity {
                Section("Machine") {
                    LabeledContent("Manufacturer", value: "ResMed")
                    if let product = productName, !product.isEmpty {
                        LabeledContent("Model", value: product)
                    }
                    if let alias = deviceAlias, !alias.isEmpty {
                        LabeledContent("Alias", value: alias)
                    }
                    if let serial = serialNumber, !serial.isEmpty {
                        LabeledContent("Serial") {
                            Text(serial).monospaced()
                        }
                    }
                }
            }

            Section("Therapy") {
                if let mode = effectiveModeName(for: s) {
                    LabeledContent("Mode", value: mode)
                }
                therapyPressureRows(for: s)
                bilevelTimingRows(for: s)
            }

            if hasComfort(s) {
                Section("Comfort") {
                    if let ramp = s.rampModeName {
                        if let minutes = s.rampTimeMinutes, ramp != "Off" {
                            LabeledContent("Ramp", value: "\(ramp) · \(minutes) min")
                        } else {
                            LabeledContent("Ramp", value: ramp)
                        }
                    }
                    if s.eprEnabled != nil {
                        LabeledContent("EPR", value: formatEPR(s))
                    }
                    if let easy = s.easyBreathe {
                        LabeledContent("Easy Breathe", value: easy ? "On" : "Off")
                    }
                    if let smart = s.smartStart {
                        LabeledContent("SmartStart", value: smart ? "On" : "Off")
                    }
                }
            }

            if hasHumidifier(s) {
                Section("Humidifier") {
                    if let climate = s.climateControlName {
                        LabeledContent("Climate Control", value: climate)
                    }
                    if let enabled = s.humidityEnabled {
                        if enabled, let level = s.humidityLevel {
                            LabeledContent("Humidity", value: "Level \(level)")
                        } else {
                            LabeledContent("Humidity", value: enabled ? "On" : "Off")
                        }
                    } else if let level = s.humidityLevel, level > 0 {
                        LabeledContent("Humidity", value: "Level \(level)")
                    }
                    if let tubeEnable = s.tubeTempEnableName {
                        if tubeEnable != "Off", let temp = s.tubeTempCelsius {
                            LabeledContent(
                                "Tube Temp",
                                value: "\(tubeEnable) · \(formatCelsius(temp))"
                            )
                        } else {
                            LabeledContent("Tube Temp", value: tubeEnable)
                        }
                    }
                    if let heated = s.heatedTube {
                        LabeledContent("Heated Tube", value: heated ? "Yes" : "No")
                    }
                }
            }

            if s.maskName != nil || s.tubeName != nil || s.antibacterialFilter != nil {
                Section("Accessories") {
                    if let mask = s.maskName {
                        LabeledContent("Mask", value: mask)
                    }
                    if let tube = s.tubeName {
                        LabeledContent("Tube", value: tube)
                    }
                    if let ab = s.antibacterialFilter {
                        LabeledContent("Antibacterial Filter", value: ab ? "Yes" : "No")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func therapyPressureRows(for s: DeviceSettings) -> some View {
        switch effectiveModeCode(for: s) {
        case 1: // CPAP
            if let p = s.cpapPressure {
                LabeledContent("Pressure", value: formatPressure(p))
            }
            if let sp = s.cpapStartPressure, sp != s.cpapPressure {
                LabeledContent("Ramp Start", value: formatPressure(sp))
            }
        case 3, 6: // AutoSet
            pressureRange(
                label: "Pressure",
                min: s.autoMinPressure,
                max: s.autoMaxPressure
            )
            if let sp = s.autoStartPressure {
                LabeledContent("Ramp Start", value: formatPressure(sp))
            }
        case 7: // AutoSet for Her
            pressureRange(
                label: "Pressure",
                min: s.autoForHerMinPressure,
                max: s.autoForHerMaxPressure
            )
            if let sp = s.autoForHerStartPressure {
                LabeledContent("Ramp Start", value: formatPressure(sp))
            }
        case 8: // VPAPauto (VAuto)
            if let maxI = s.vautoMaxIPAP {
                LabeledContent("Max IPAP", value: formatPressure(maxI))
            }
            if let minE = s.vautoMinEPAP {
                LabeledContent("Min EPAP", value: formatPressure(minE))
            }
            if let ps = s.vautoPressureSupport {
                LabeledContent("Pressure Support", value: formatPressure(ps))
            }
            if let sp = s.vautoStartPressure {
                LabeledContent("Ramp Start", value: formatPressure(sp))
            }
        case 9, 10: // VPAP S / ST (BiLevel)
            if let ipap = s.bilevelIPAP {
                LabeledContent("IPAP", value: formatPressure(ipap))
            }
            if let epap = s.bilevelEPAP {
                LabeledContent("EPAP", value: formatPressure(epap))
            }
            if let sp = s.bilevelStartPressure {
                LabeledContent("Ramp Start", value: formatPressure(sp))
            }
        default:
            // Fallback — surface whichever pressure group has data.
            if let p = s.cpapPressure {
                LabeledContent("Pressure", value: formatPressure(p))
            }
            pressureRange(
                label: "Pressure",
                min: s.autoMinPressure,
                max: s.autoMaxPressure
            )
        }
    }

    /// Bilevel/VAuto-only timing + sensitivity rows (TiMin/TiMax,
    /// Trigger, Cycle, Rise Time). Split out so both pressure-mode
    /// branches can include them without duplicating the gated
    /// `if let` structure.
    @ViewBuilder
    private func bilevelTimingRows(for s: DeviceSettings) -> some View {
        if let trigger = s.triggerSensitivityName {
            LabeledContent("Trigger", value: trigger)
        }
        if let cycle = s.cycleSensitivityName {
            LabeledContent("Cycle", value: cycle)
        }
        if let ti = s.tiMinSeconds {
            LabeledContent("TiMin", value: formatSeconds(ti))
        }
        if let ti = s.tiMaxSeconds {
            LabeledContent("TiMax", value: formatSeconds(ti))
        }
        if let enabled = s.riseTimeEnabled {
            if enabled, let ms = s.riseTimeMs {
                LabeledContent("Rise Time", value: "\(ms) ms")
            } else {
                LabeledContent("Rise Time", value: enabled ? "On" : "Off")
            }
        }
    }

    @ViewBuilder
    private func pressureRange(label: String, min: Double?, max: Double?) -> some View {
        if let min, let max {
            LabeledContent(
                label,
                value: "\(formatPressure(min)) – \(formatPressure(max))"
            )
        } else if let min {
            LabeledContent(label, value: "Min \(formatPressure(min))")
        } else if let max {
            LabeledContent(label, value: "Max \(formatPressure(max))")
        }
    }

    /// Human label for the effective mode. Falls back to the raw
    /// `modeName` from `DeviceSettings` when the effective code
    /// matches the raw code, otherwise builds a label from the
    /// effective code via a local lookup so what's shown in the
    /// Mode row agrees with which pressure rows render below.
    private func effectiveModeName(for s: DeviceSettings) -> String? {
        let effective = effectiveModeCode(for: s)
        if effective == s.modeCode { return s.modeName }
        switch effective {
        case 1:       return "CPAP"
        case 2:       return "APAP"
        case 3, 6:    return "AutoSet"
        case 7:       return "AutoSet for Her"
        case 8:       return "VPAPauto"
        case 9:       return "VPAP S"
        case 10:      return "VPAP ST"
        case 11:      return "iVAPS"
        case 12:      return "ASV"
        case 13:      return "ASVauto"
        default:      return effective.map { "Mode \($0)" }
        }
    }

    /// Derive the therapy-mode code we should actually branch on.
    /// The raw `S.Mode` field is normally the authoritative signal,
    /// but if the mode's own pressure group is empty (e.g. a device
    /// reports `Mode = 6` while only populating `S.VA.*`, as happens
    /// on flashed AS10 units), fall back to whichever pressure group
    /// the firmware actually wrote data to. Product name is NOT used
    /// for locking — some devices run firmware that exposes modes
    /// their marketing name doesn't suggest.
    private func effectiveModeCode(for s: DeviceSettings) -> Int? {
        if let raw = s.modeCode, pressureGroupPopulated(forMode: raw, in: s) {
            return raw
        }
        // Raw mode code had no matching pressure data — pick whichever
        // group the device actually wrote values for. Preference order
        // mirrors clinical prevalence (VAuto > BiLevel > AutoSet > CPAP)
        // so multi-populated firmware lands on the more specific mode.
        if s.vautoMaxIPAP != nil || s.vautoMinEPAP != nil { return 8 }
        if s.bilevelIPAP != nil || s.bilevelEPAP != nil { return 9 }
        if s.autoForHerMinPressure != nil || s.autoForHerMaxPressure != nil { return 7 }
        if s.autoMinPressure != nil || s.autoMaxPressure != nil { return 3 }
        if s.cpapPressure != nil { return 1 }
        return s.modeCode
    }

    /// Return `true` when the pressure group that corresponds to
    /// `mode` has any of its primary fields populated — used to
    /// decide whether the raw mode code is trustworthy or whether
    /// we should fall through to data-driven inference.
    private func pressureGroupPopulated(forMode mode: Int, in s: DeviceSettings) -> Bool {
        switch mode {
        case 1:       return s.cpapPressure != nil
        case 3, 6:    return s.autoMinPressure != nil || s.autoMaxPressure != nil
        case 7:       return s.autoForHerMinPressure != nil || s.autoForHerMaxPressure != nil
        case 8:       return s.vautoMaxIPAP != nil || s.vautoMinEPAP != nil
        case 9, 10:   return s.bilevelIPAP != nil || s.bilevelEPAP != nil
        default:      return false
        }
    }

    private func formatPressure(_ value: Double) -> String {
        String(format: "%.1f cmH₂O", value)
    }

    private func formatCelsius(_ value: Double) -> String {
        String(format: "%.0f°C", value)
    }

    /// Render Ti / rise-time seconds as "2 s", "0.3 s", etc. — the
    /// device shows whole-second values with no decimal and
    /// sub-second values to one decimal.
    private func formatSeconds(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f s", value)
        }
        return String(format: "%.1f s", value)
    }

    private func formatEPR(_ s: DeviceSettings) -> String {
        guard let enabled = s.eprEnabled else { return "—" }
        guard enabled else { return "Off" }
        var parts: [String] = ["On"]
        if let level = s.eprLevel { parts.append("Level \(level)") }
        if let type = s.eprTypeName { parts.append(type) }
        return parts.joined(separator: " · ")
    }

    private func hasComfort(_ s: DeviceSettings) -> Bool {
        s.rampEnableCode != nil
            || s.eprEnabled != nil
            || s.easyBreathe != nil
            || s.smartStart != nil
    }

    /// Best-effort human name for the current device — used in the
    /// empty-state copy so a reader sees "Your Upstairs CPAP…" or
    /// "Your AirSense 10 CPAP…" instead of a generic "Your CPAP…".
    /// Prefers the user-set alias, falls back to the product name,
    /// and lands on the generic "CPAP" when neither is available.
    private var friendlyDeviceName: String {
        if let alias = deviceAlias, !alias.isEmpty { return alias }
        if let product = productName, !product.isEmpty { return product }
        if let deviceType, !deviceType.isEmpty { return deviceType }
        return "Machine"
    }

    /// `true` when we have enough identity data to justify showing
    /// the Device section. Manufacturer alone is not interesting —
    /// there needs to be at least a product name or serial.
    private var hasDeviceIdentity: Bool {
        (productName?.isEmpty == false)
            || (serialNumber?.isEmpty == false)
            || (deviceAlias?.isEmpty == false)
    }

    private func hasHumidifier(_ s: DeviceSettings) -> Bool {
        s.climateControlCode != nil
            || s.humidityEnabled != nil
            || s.humidityLevel != nil
            || s.tubeTempEnableCode != nil
            || s.tubeTempCelsius != nil
            || s.heatedTube != nil
    }
}
