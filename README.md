# Snorecard

A native Mac and iPhone app for reading the data your ResMed CPAP machine writes to its SD card.

If you use a ResMed AirSense or AirCurve, your machine quietly records every breath of every night. Snorecard reads those recordings and shows you what happened — your AHI, how long you slept on therapy, when events clustered during the night, what pressure your machine was actually delivering, and how it all changes over time.

## What it shows you

**Each night**

- Your AHI for the night, broken down into obstructive apnea, hypopnea, clear airway / central apnea, and any unclassified apneas your machine couldn't categorize. CA events have their own label and visibility toggle in Settings — hide them from the AHI calculation, charts, and totals if your clinician has told you they're arousal artefacts unrelated to therapy
- Quick-glance cards for usage hours, time spent in apnea, EPAP, IPAP, leak, flow limitation, snore, and tidal volume — colored green / amber / red so you can see at a glance where the night sat
- A bar chart showing when events happened hour by hour
- Hourly charts for leak, flow limitation, pressure, tidal volume, and Glasgow Index — the tidal-volume and Glasgow lines mark the night's overall median / average so each hour reads as above or below typical
- Detailed percentile statistics for every signal your machine recorded, including breath timing and a per-event breakdown
- An Advanced Charting window with the full waveform of breathing, mask pressure, leak, snore, and tidal volume — with a draggable scrubber that focuses any window of the night
- A Therapy Sessions list with an include / exclude switch on every session, so a stray mask test or daytime fitting can be dropped from the day's AHI, usage, and pressure totals. Sessions under two minutes are excluded automatically — they're almost always fittings rather than therapy
- A per-session mask label so you can record which of your masks you wore for each session — handy when you swap mid-night or are trialing a new cushion
- Your machine's exact therapy settings for that specific night — pressure, mode, EPR, ramp, humidifier, mask type, and more
- A Sleep Journal entry for writing your own notes about the night

**Apple Watch sleep stages**

If you wear an Apple Watch to bed, Snorecard pulls the watch's deep / core / REM detections from Health and lays them alongside your therapy data, with no data ever leaving your iCloud account.

- A **Sleep Stages tint** layered behind the session bars on the Detailed Waveforms timeline — the colored backdrop tells you which stages the watch detected during each part of the recording
- A **Sleep by Hour** chart that stacks deep / core / REM minutes per clock hour with your CPAP / APAP / BiPAP / ASV mask-on minutes overlaid as a line, so you can spot whether your therapy time aligned with your actual sleep
- **Deep Sleep** and **REM Sleep** percentage chips on the day view and Trends, including range averages
- A **Stage minutes per night** chart in Trends showing how the architecture of your sleep changes across a 7 / 14 / 30-day window
- The Apple Intelligence narratives reference your sleep architecture when a watch summary exists

**Across all your nights**

- Compliance, average AHI (with obstructive / hypopnea / clear airway breakdown), average usage, average deep and REM sleep, and other long-running averages
- A [Glasgow Index](https://www.fortaspen.com/sleep/Intro.html) score for breath quality
- Trend charts you can filter to the last 7 / 14 / 30 days or a custom range
- Tap any chart to jump straight to that day
- A device-wide Sleep Journal for notes that span more than one night

**Across all your devices**

- Switch between multiple ResMed machines if you have more than one
- Give each device a friendly name that follows you to your other Apple devices
- Everything syncs through your iCloud account — import once on your Mac, see it on your iPhone
- Pick from eight app-icon variants built in Icon Composer

**Mask tracking**

- Keep a list of the masks you actually wear, with manufacturer (ResMed, Philips Respironics, Fisher & Paykel, Bleep, or Other), model, type (full face / nasal / pillow / hybrid), and size
- Pick one as the default — newly imported sessions are automatically labeled with whatever you were wearing the night you imported them
- Change the mask on any individual session from the Therapy Sessions list when you swapped mid-night or are trying a new cushion
- Bulk-apply a mask to past sessions across a date range, so switching masks last Tuesday only takes a few taps to reflect across all those nights
- Your mask catalog and per-session labels sync across all your Apple devices through iCloud

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

Apple Watch sleep data is imported from your iPhone's Health store and saved alongside the rest of your CPAP data in your own iCloud Drive container. Your Mac picks the summaries up automatically once iCloud has synced them, so the timeline tint and Trends averages are available on both platforms — import once on the iPhone, view anywhere. Snorecard reads sleep samples from Health but never writes anything back.

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
