import Foundation
import SnorecardKit

// Exercises SnorecardKit against a real ResMed SD card folder and prints a summary.
// Acts as a stand-in for unit tests while Xcode (and XCTest) aren't available.
// Usage: swift run snorecard-probe [/path/to/SD]

let arguments = CommandLine.arguments
let rootPath = arguments.count > 1 ? arguments[1] : "/Users/vmstan/SD"
let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

print("Snorecard probe — scanning: \(rootURL.path)\n")

let card: ResMedSDCard
do {
    card = try SDCardImporter.scan(rootURL)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

if let id = card.identification {
    print("Device: \(id.productName ?? "unknown")")
    print("  serial:    \(id.serialNumber ?? "-")")
    print("  model ID:  \(id.modelID ?? "-")")
    print("  firmware:  \(id.firmware ?? "-")")
} else {
    print("Device: (no Identification.tgt)")
}

print("Days on card: \(card.days.count)")
for day in card.days {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let dateString = formatter.string(from: day.date)
    let counts = Dictionary(grouping: day.files, by: \.kind)
        .mapValues(\.count)
        .sorted { $0.key.rawValue < $1.key.rawValue }
        .map { "\($0.key.rawValue):\($0.value)" }
        .joined(separator: " ")
    let fl95 = day.stats?.flowLimit95.map { String(format: "%.4f", $0) } ?? "nil"
    let gi = day.stats?.glasgowIndex.map { String(format: "%.4f", $0) } ?? "nil"
    print("  \(dateString)  \(counts)  flowLimit95=\(fl95)  glasgow=\(gi)")
}

print()

// Parse STR.edf summary header.
if let strURL = card.summaryFileURL {
    let str = try EDFFile(contentsOf: strURL)
    print("STR.edf")
    print("  kind:       \(str.header.kind)")
    print("  signals:    \(str.header.signalCount)")
    print("  records:    \(str.header.recordCount) × \(str.header.recordDuration)s")
    print("  start:      \(str.header.startDate)")
    let labels = str.signals.prefix(10).map(\.label).joined(separator: ", ")
    print("  first 10:   \(labels)")
}

print()

// Pressure debug — compare STR.edf TgtEPAP.95 to PLD-computed percentile.
if let lastDay = card.days.last(where: { !$0.files(of: .physiological).isEmpty }) {
    var epaps: [Double] = []
    var ipaps: [Double] = []
    var mps: [Double] = []
    for file in lastDay.files(of: .physiological) {
        guard let edf = try? EDFFile(contentsOf: file.url),
              edf.header.recordCount > 0 else { continue }
        func decode(_ prefix: String) -> [Double] {
            guard let idx = edf.signals.firstIndex(where: { $0.label.hasPrefix(prefix) }),
                  let s = try? edf.physicalSamples(ofSignal: idx) else { return [] }
            return s
        }
        let mp = decode("MaskPress")
        let ep = decode("EprPress")
        let ip = decode("Press.")
        for i in mp.indices where mp[i] > 1.0 {
            mps.append(mp[i])
            if i < ep.count { epaps.append(ep[i]) }
            if i < ip.count { ipaps.append(ip[i]) }
        }
    }
    func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        var s = v; s.sort()
        let rank = (p / 100) * Double(s.count - 1)
        let low = Int(rank.rounded(.down))
        let high = min(low + 1, s.count - 1)
        let frac = rank - Double(low)
        return s[low] * (1 - frac) + s[high] * frac
    }
    print("PLD-computed percentiles (on-therapy):")
    print("  MaskPress.95 = \(String(format: "%.4f", percentile(mps, 95)))")
    print("  EprPress.95  = \(String(format: "%.4f", percentile(epaps, 95)))")
    print("  Press.95     = \(String(format: "%.4f", percentile(ipaps, 95)))")
}

// Glasgow Index debug
if let lastDay = card.days.last(where: { !$0.files(of: .breath).isEmpty }) {
    let gi = GlasgowIndex.computeDay(brpFiles: lastDay.files(of: .breath))
    print("Glasgow Index (weighted): \(gi.map { String(format: "%.4f", $0.score) } ?? "nil")")
    for file in lastDay.files(of: .breath) {
        guard let edf = try? EDFFile(contentsOf: file.url),
              edf.header.recordCount > 0,
              let idx = edf.signals.firstIndex(where: { $0.label.hasPrefix("Flow") }),
              let decoded = try? edf.physicalSamples(ofSignal: idx)
        else { continue }
        let unit = edf.signals[idx].physicalDimension
            .trimmingCharacters(in: .whitespaces).lowercased()
        let scale: Double = unit.contains("l/s") ? 60 : 1
        let result = GlasgowIndex.compute(flowSamples: decoded.map { $0 * scale })
        print("  \(file.url.lastPathComponent): score=\(result.map { String(format: "%.4f", $0.score) } ?? "nil") inspirations=\(result?.inspirationCount ?? 0)")
    }
}

print()

// Pull the most recent breath-waveform file and summarize it.
if let lastDay = card.days.last,
   let brp = lastDay.files(of: .breath).first {
    let file = try EDFFile(contentsOf: brp.url)
    print("BRP sample: \(brp.url.lastPathComponent)")
    print("  kind:       \(file.header.kind)")
    print("  records:    \(file.header.recordCount) × \(file.header.recordDuration)s")
    print("  duration:   \(Double(file.header.recordCount) * file.header.recordDuration)s")
    for (i, signal) in file.signals.enumerated() {
        let sampleRate = signal.samplesPerRecord > 0 && file.header.recordDuration > 0
            ? Double(signal.samplesPerRecord) / file.header.recordDuration
            : 0
        print("  [\(i)] \(signal.label) — \(signal.physicalDimension), "
              + "\(String(format: "%.1f", sampleRate)) Hz, "
              + "range \(signal.physicalMin)..\(signal.physicalMax)")
    }

    // Decode the first numeric signal's samples as a smoke test.
    if let flowIndex = file.signals.firstIndex(where: { !$0.isAnnotation }) {
        let samples = try file.physicalSamples(ofSignal: flowIndex)
        let signal = file.signals[flowIndex]
        let min = samples.min() ?? 0
        let max = samples.max() ?? 0
        let mean = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
        print("  decoded [\(flowIndex)] \(signal.label): "
              + "\(samples.count) samples, "
              + "min=\(String(format: "%.2f", min)), "
              + "max=\(String(format: "%.2f", max)), "
              + "mean=\(String(format: "%.2f", mean))")
    }
}

print()

// Pull the most recent events file and decode its annotations.
if let lastDay = card.days.last,
   let eve = lastDay.files(of: .events).first {
    let file = try EDFFile(contentsOf: eve.url)
    let annotations = try file.annotations()
    print("EVE sample: \(eve.url.lastPathComponent)")
    print("  annotations: \(annotations.count)")
    for annotation in annotations.prefix(8) {
        let dur = annotation.duration.map { String(format: "%.1fs", $0) } ?? "-"
        print("    +\(annotation.onset)s [\(dur)]  \(annotation.text)")
    }
    if annotations.count > 8 {
        print("    … \(annotations.count - 8) more")
    }

    let counts = Dictionary(grouping: annotations, by: \.text).mapValues(\.count)
    if !counts.isEmpty {
        print("  by type:")
        for (text, count) in counts.sorted(by: { $0.value > $1.value }) {
            print("    \(count)× \(text)")
        }
    }
}

print("\n--- STR.edf signal dump ---")
if let strURL = card.summaryFileURL {
    let str = try EDFFile(contentsOf: strURL)
    for (index, signal) in str.signals.enumerated() {
        let values = (try? str.physicalSamples(ofSignal: index)) ?? []
        let formatted = values
            .map { String(format: "%.2f", $0) }
            .joined(separator: ", ")
        print("  [\(String(format: "%02d", index))] \(signal.label.padding(toLength: 24, withPad: " ", startingAt: 0)) "
              + "unit=\(signal.physicalDimension.padding(toLength: 8, withPad: " ", startingAt: 0)) "
              + "range=\(signal.physicalMin)..\(signal.physicalMax)  "
              + "values=[\(formatted)]")
    }
}

print("\n--- PLD sample ---")
if let pld = card.days.last(where: { !$0.files(of: .physiological).isEmpty })?
    .files(of: .physiological).first {
    let file = try EDFFile(contentsOf: pld.url)
    print("  file: \(pld.url.lastPathComponent)")
    print("  records: \(file.header.recordCount) × \(file.header.recordDuration)s")
    for (i, signal) in file.signals.enumerated() {
        let rate = file.header.recordDuration > 0
            ? Double(signal.samplesPerRecord) / file.header.recordDuration
            : 0
        print("  [\(i)] \(signal.label) unit=\(signal.physicalDimension) \(String(format: "%.2f", rate)) Hz range=\(signal.physicalMin)..\(signal.physicalMax)")
    }
}

print("\n--- full BRP sweep ---")
for day in card.days {
    for file in day.files(of: .breath) {
        let label = file.url.lastPathComponent
        do {
            let f = try EDFFile(contentsOf: file.url)
            let recs = f.header.recordCount
            let sigs = f.signals.map { "\($0.label)@\($0.samplesPerRecord)" }.joined(separator: ",")
            print("  \(label)  records=\(recs)  signals=[\(sigs)]")
            if f.header.recordCount >= 0 {
                for idx in f.signals.indices where !f.signals[idx].isAnnotation {
                    do {
                        _ = try f.physicalSamples(ofSignal: idx)
                    } catch {
                        print("    signal[\(idx)] \(f.signals[idx].label) FAILED: \(error)")
                    }
                }
            } else {
                print("    recordCount is negative — would trap loop")
            }
        } catch {
            print("  \(label)  HEADER FAILED: \(error)")
        }
    }
}

print("\nOK")
