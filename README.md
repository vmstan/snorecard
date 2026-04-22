# Snorecard

A native Mac and iPhone app for reading the data your ResMed CPAP machine writes to its SD card.

If you use a ResMed AirSense or AirCurve, your machine quietly records every breath of every night. Snorecard reads those recordings and shows you what happened — your AHI, how long you slept on therapy, when events clustered during the night, what pressure your machine was actually delivering, and how it all changes over time.

## What it shows you

**Each night**

- Your AHI for the night, broken down into obstructive apnea, hypopnea, and central apnea
- Quick-glance cards for usage hours, time spent in apnea, EPAP, IPAP, leak, flow limitation, snore, and tidal volume — colored green / amber / red so you can see at a glance where the night sat
- A bar chart showing when events happened hour by hour
- Hourly charts for leak, flow limitation, and pressure
- Detailed percentile statistics for every signal your machine recorded, including breath timing and a per-event breakdown
- An Advanced Charting window with the full waveform of breathing, mask pressure, leak, snore, and tidal volume — with a draggable scrubber that focuses any window of the night
- Your machine's exact therapy settings for that specific night — pressure, mode, EPR, ramp, humidifier, mask type, and more
- A Sleep Journal entry for writing your own notes about the night

**Across all your nights**

- Compliance, average AHI (with obstructive / hypopnea / central breakdown), average usage, and other long-running averages
- A [Glasgow Index](https://www.fortaspen.com/sleep/Intro.html) score for breath quality
- Trend charts you can filter to the last 7 / 14 / 30 days or a custom range
- Tap any chart to jump straight to that day
- A device-wide Sleep Journal for notes that span more than one night

**Across all your devices**

- Switch between multiple ResMed machines if you have more than one
- Give each device a friendly name that follows you to your other Apple devices
- Everything syncs through your iCloud account — import once on your Mac, see it on your iPhone
- Pick from eight app-icon variants built in Icon Composer

**Backup**

- One-click backups of an entire device's data into your iCloud Drive
- Restore from any backup, including across devices

## On-device sleep analysis

Snorecard uses Apple Intelligence to turn your raw therapy data into plain-English narratives — entirely on-device. Nothing about your nights ever leaves your Mac or iPhone.

- **Sleep Analysis** — a narrative read on how your recent nights are trending, available from Trends
- **Explain this metric** — tap any card (AHI, usage, pressure, Glasgow Index, flow limitation, time in apnea, and more) for a contextual interpretation grounded in *your* numbers, not a generic definition
- **Per-night summaries** — a short recap of how a specific night went and how it compared to the ones around it
- **Correlation hints** — patterns the app notices between your therapy data and your Sleep Journal entries

If your device doesn't support Apple Intelligence, or you've turned it off, these surfaces simply don't appear — the rest of the app works exactly the same.

## Requirements

- macOS 26 or iOS 26
- An iCloud account (used for sync between your devices)
- A ResMed AirSense or AirCurve SD card
- Apple Intelligence is optional — used only for the on-device narratives above

## Privacy

Snorecard is a viewer — it doesn't send your data anywhere except your own iCloud account, which is what keeps your nights synced between your Mac and iPhone. There are no third-party accounts, no tracking, and no analytics. The Apple Intelligence narratives run on Apple's on-device Foundation Models; your therapy data is never sent to a server.

## A note on accuracy

Snorecard is a personal-use viewer for your therapy data, not a medical device or diagnostic tool. The numbers it shows come straight from your CPAP machine, but interpretation belongs to you and your sleep clinician.

## Building from source

Snorecard is open source. To build it yourself you'll need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
xcodegen generate
xcodebuild -project Snorecard.xcodeproj -scheme Snorecard -destination 'platform=macOS' build
```

The parsing library is also a Swift package and includes a small command-line tool for inspecting an SD card directly:

```
swift run snorecard-probe /path/to/SD
```

## Acknowledgements

- Breath-quality scoring uses a Swift port of [DaveSkvn/GlasgowIndex](https://github.com/DaveSkvn/GlasgowIndex).
- The wider CPAP open-source community — especially the OSCAR project — for years of reverse-engineering ResMed's data formats.

## License

All rights reserved.
