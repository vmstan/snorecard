# Snorecard

A native macOS and iOS app for reading and visualizing data from ResMed CPAP/BiPAP SD cards.

Snorecard parses the EDF files and summary records stored on a ResMed device's SD card, then presents nightly statistics, event breakdowns, pressure graphs, and waveform data in a SwiftUI interface.

## Features

- Import data directly from a ResMed SD card or a previously saved backup folder
- Daily statistics: usage hours, AHI, leak rates, pressure percentiles, respiratory metrics
- Event timeline with apnea/hypopnea annotations from EVE files
- Waveform visualization for flow, pressure, and leak signals
- Overview with trends across multiple nights
- Back up SD card data to a local folder or iCloud Drive
- iCloud sync keeps one snapshot per device, accessible from any Mac or iOS device

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

## Project Structure

- **Snorecard/** -- Shared SwiftUI views and app logic (cross-platform)
- **Snorecard-macOS/** -- macOS app entry point and menu commands
- **Snorecard-iOS/** -- iOS app entry point
- **Sources/SnorecardKit/** -- SD card importer, EDF parser, ResMed data models
- **Sources/SnorecardProbe/** -- CLI tool for inspecting SD card contents

## License

All rights reserved.
