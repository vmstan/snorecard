# Snorecard

A native macOS and iOS app for reading and analyzing data from ResMed CPAP/BiPAP SD cards.

Snorecard parses the EDF files and summary records stored on a ResMed device's SD card, then presents nightly statistics, event breakdowns, pressure graphs, and waveform data in a SwiftUI interface. Pressure, flow limit, and leak percentiles are computed directly from the raw PLD samples.

## Features

- Import data from a ResMed SD card — incremental merges only copy missing days
- Per-device identification (AirSense 10-family `Identification.tgt` and AirSense 11 `Identification.json`), with AirSense 11 mode-code remapping back to the S9/AS10 enum
- Multi-machine support with a sidebar device picker; rename any device with a custom alias that syncs across devices via iCloud
- Daily view with the night's AHI / OA / H / CA donut, stat cards (Usage, Time in Apnea, Glasgow Index, Pressure, Flow Limit, Leak, Large Leak, Tidal Volume) — each color-coded by clinical severity — plus an Events-by-Hour chart and a collapsible **Detailed Statistics** percentile table (Median / 95% / 99.5%) that opens in its own window on macOS
- **Therapy Details** inspector showing the per-night `S.*` settings block decoded from STR.edf — mode, pressure setpoints (CPAP / AutoSet / VAuto / BiLevel), comfort (EPR, Ramp, Easy Breathe, Smart Start, Trigger / Cycle / Ti / Rise Time), humidifier, and accessories — with field-level merge so a partial STR rewrite never blanks a previously-decoded field
- **Sleep Journal** — free-form per-night notes that ride iCloud as `.snorecard-notes.json` sidecars
- **Backup & Restore** — Apple Archive (LZFSE) snapshots of an entire device folder, stored in iCloud Drive and restorable across devices. macOS uses Spotlight-style floating windows with traffic-light controls
- Waveform viewer for breathing, pressure (IPAP + EPAP), leak, flow limitation, tidal volume, and snore — with pinch / preset zoom, a draggable session-timeline scrubber, and a floating hover readout
- Overview view with Days, Compliance, AHI, Glasgow Index, and trend charts — filterable by All / 7 / 14 / 30 days / Custom; click any chart to drill into that day's detail view
- [Glasgow Index](https://github.com/DaveSkvn/GlasgowIndex) port for per-breath quality scoring
- iCloud sync keeps every device's data accessible from any Mac or iPhone — including the sidecar-cached daily stats, settings, notes, and backups
- Per-day stats sidecar cache + on-disk card snapshot — warm launches paint the sidebar in milliseconds, with day aggregates streaming in progressively
- Sandboxed macOS app, eligible for the App Store
- Liquid Glass app icon authored in Icon Composer (Xcode 26+)

## Requirements

- macOS 26+ / iOS 26+
- Xcode 26+
- Swift 6.2+

## Building

The Xcode project is generated from `project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
xcodegen generate
xcodebuild -project Snorecard.xcodeproj -scheme Snorecard -destination 'platform=macOS' build
```

The core parsing library (SnorecardKit) is also a Swift package and can be built standalone:

```
swift build
```

A CLI probe is included for inspecting a card's contents:

```
swift run snorecard-probe /path/to/SD
```

## Project Structure

- **Snorecard/** — Shared SwiftUI views and app logic (cross-platform)
- **Snorecard-macOS/** — macOS app entry point and menu commands
- **Snorecard-iOS/** — iOS app entry point
- **Sources/SnorecardKit/** — SD card importer, EDF parser, ResMed data models, Glasgow Index port, per-day stats cache
- **Sources/SnorecardProbe/** — CLI tool for inspecting SD card contents

## Acknowledgements

- [DaveSkvn/GlasgowIndex](https://github.com/DaveSkvn/GlasgowIndex) — flow-quality index ported to Swift in `GlasgowIndex.swift`

## License

All rights reserved.
