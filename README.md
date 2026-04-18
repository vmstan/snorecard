# Snorecard

A native Mac and iPhone app for reading the data your ResMed CPAP machine writes to its SD card.

If you use a ResMed AirSense or AirCurve, your machine quietly records every breath of every night. Snorecard reads those recordings and shows you what happened — your AHI, how long you slept on therapy, when events clustered during the night, what pressure your machine was actually delivering, and how it all changes over time.

## What it shows you

**Each night**

- Your AHI for the night, broken down into obstructive apnea, hypopnea, and central apnea
- Quick-glance cards for usage hours, time spent in apnea, pressure, leak, flow limitation, and tidal volume — colored green / amber / red so you can see at a glance where the night sat
- A bar chart showing when events happened hour by hour
- Detailed percentile statistics for every signal your machine recorded
- The full waveform of breathing, mask pressure, leak, snore, and tidal volume — with a draggable scrubber that focuses any window of the night
- Your machine's exact therapy settings for that specific night — pressure, mode, EPR, ramp, humidifier, mask type, and more
- A space to write your own notes about the night

**Across all your nights**

- Compliance, average AHI, average usage, and other long-running averages
- A [Glasgow Index](https://www.fortaspen.com/sleep/Intro.html) score for breath quality
- Trend charts you can filter to the last 7 / 14 / 30 days or a custom range
- Tap any chart to jump straight to that day

**Across all your devices**

- Switch between multiple ResMed machines if you have more than one
- Give each device a friendly name that follows you to your other Apple devices
- Everything syncs through your iCloud account — import once on your Mac, see it on your iPhone

**Backup**

- One-click backups of an entire device's data into your iCloud Drive
- Restore from any backup, including across devices

## Requirements

- macOS 26 or iOS 26
- An iCloud account (used for sync between your devices)
- A ResMed AirSense or AirCurve SD card

## Privacy

Snorecard is a viewer — it doesn't send your data anywhere except your own iCloud account, which is what keeps your nights synced between your Mac and iPhone. There are no third-party accounts, no tracking, no analytics.

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
