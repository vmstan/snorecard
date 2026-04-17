import SwiftUI
import SnorecardKit

/// Sliding inspector on the daily view that shows the CPAP
/// device's settings active for that night — decoded from
/// `STR.edf`. Matches the layout / style of the Rename Device
/// sheet (grouped Form, labeled rows) so the app has one
/// consistent surface for structured data.
struct DailySettingsInspector: View {
    let settings: DeviceSettings?

    var body: some View {
        Group {
            if let settings, settings.hasAnyValue {
                settingsForm(for: settings)
            } else {
                ContentUnavailableView {
                    Label("Settings unavailable", systemImage: "slider.horizontal.3")
                } description: {
                    Text("STR.edf didn't cover this day, so the therapy settings couldn't be read.")
                }
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Form

    @ViewBuilder
    private func settingsForm(for s: DeviceSettings) -> some View {
        Form {
            Section("Therapy") {
                if let mode = s.modeName {
                    LabeledContent("Mode", value: mode)
                }
                therapyPressureRows(for: s)
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

            if s.maskName != nil || s.tubeName != nil {
                Section("Accessories") {
                    if let mask = s.maskName {
                        LabeledContent("Mask", value: mask)
                    }
                    if let tube = s.tubeName {
                        LabeledContent("Tube", value: tube)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func therapyPressureRows(for s: DeviceSettings) -> some View {
        switch s.modeCode {
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

    private func formatPressure(_ value: Double) -> String {
        String(format: "%.1f cmH₂O", value)
    }

    private func formatCelsius(_ value: Double) -> String {
        String(format: "%.0f°C", value)
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

    private func hasHumidifier(_ s: DeviceSettings) -> Bool {
        s.climateControlCode != nil
            || s.humidityEnabled != nil
            || s.humidityLevel != nil
            || s.tubeTempEnableCode != nil
            || s.tubeTempCelsius != nil
            || s.heatedTube != nil
    }
}
