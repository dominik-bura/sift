import SwiftUI

enum SiftChartStyle {
    static let accent = Color(red: 0.96, green: 0.36, blue: 0.28)
    static let rule = Color.primary.opacity(0.12)
    // Explicit colors avoid the extra vibrancy attenuation of hierarchical
    // secondary/tertiary ShapeStyles over nested translucent surfaces.
    static let secondaryText = label(dark: 0.78, light: 0.30)
    static let mutedText = label(dark: 0.64, light: 0.40)
    static func inventoryColor(for categoryID: String) -> Color {
        // Categorical, not a savings/risk scale. Key by ID so an empty or
        // missing category never shifts the remaining colors.
        let dark: (CGFloat, CGFloat, CGFloat)
        let light: (CGFloat, CGFloat, CGFloat)
        switch categoryID {
        case "worktrees":
            dark = (0.51, 0.67, 0.61); light = (0.31, 0.48, 0.40) // sage
        case CacheCategory.packages.id:
            dark = (0.53, 0.66, 0.78); light = (0.33, 0.46, 0.60) // dusty blue
        case CacheCategory.apps.id:
            dark = (0.69, 0.60, 0.75); light = (0.48, 0.36, 0.55) // lavender
        case CacheCategory.developerTools.id:
            dark = (0.75, 0.65, 0.49); light = (0.55, 0.43, 0.25) // sand
        default: return mutedText
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
    private static func label(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
}

/// Rounded cells are a visual scale, not a count of files or disk blocks.
struct StorageBlockBar: View {
    let fraction: Double
    var hatched = false
    var accent = false
    var cells = 36

    var body: some View {
        Canvas { context, size in
            let count = max(1, cells), gap: CGFloat = 2
            let width = max(0, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
            let filled = Int((min(1, max(0, fraction.isFinite ? fraction : 0)) * Double(count)).rounded())
            for index in 0..<count {
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                let shape = Path(roundedRect: rect, cornerRadius: min(2, width / 3))
                context.fill(shape, with: .color(index < filled ? (accent ? SiftChartStyle.accent : .primary.opacity(0.42)) : .primary.opacity(0.07)))
                if hatched && index < filled {
                    var clipped = context
                    clipped.clip(to: shape)
                    var lines = Path()
                    for x in stride(from: rect.minX - size.height, through: rect.maxX + size.height, by: 5) {
                        lines.move(to: CGPoint(x: x, y: size.height))
                        lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                    }
                    clipped.stroke(lines, with: .color(.primary.opacity(0.45)), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct StorageUncertaintyKey: View {
    var body: some View {
        HStack(spacing: 6) {
            StorageBlockBar(fraction: 1, hatched: true, cells: 4).frame(width: 28, height: 7)
            Text("Attributed size · not guaranteed freed space")
        }.font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
    }
}

struct DiskSpaceSample: Codable, Equatable, Sendable {
    let date: Date
    let freeBytes: Int64
    let capacity: Int64
    let cleanup: Bool
}

struct DiskSpaceHistory {
    private(set) var samples: [DiskSpaceSample]
    init(samples: [DiskSpaceSample] = []) {
        self.samples = samples.filter { $0.freeBytes >= 0 && $0.capacity > 0 && $0.freeBytes <= $0.capacity }
            .sorted { $0.date < $1.date }
    }
    @discardableResult mutating func record(free: Int64, capacity: Int64, date: Date = Date(), cleanup: Bool = false) -> Bool {
        guard free >= 0, capacity > 0, free <= capacity else { return false }
        if let last = samples.last, !cleanup, date.timeIntervalSince(last.date) < 900 { return false }
        samples.append(DiskSpaceSample(date: date, freeBytes: free, capacity: capacity, cleanup: cleanup))
        samples = Array(samples.filter { date.timeIntervalSince($0.date) <= 30 * 86_400 }.suffix(2_880))
        return true
    }
}

struct DiskSpaceHistoryView: View {
    let samples: [DiskSpaceSample]
    private var recent: [DiskSpaceSample] { Array(samples.suffix(96)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FREE SPACE").font(.caption2.weight(.semibold)).tracking(0.8)
                Spacer()
                Text("Local history").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
            }.foregroundStyle(SiftChartStyle.secondaryText)
            if recent.count > 1, let first = recent.first, let last = recent.last {
                let low = recent.map(\.freeBytes).min() ?? 0
                let high = max(low + 1_000_000, recent.map(\.freeBytes).max() ?? 0)
                HStack(alignment: .top, spacing: 10) {
                    Canvas { context, size in
                        let duration = max(1, last.date.timeIntervalSince(first.date))
                        func point(_ sample: DiskSpaceSample) -> CGPoint {
                            CGPoint(x: size.width * sample.date.timeIntervalSince(first.date) / duration,
                                    y: 4 + (size.height - 8) * (1 - Double(sample.freeBytes - low) / Double(high - low)))
                        }
                        var rule = Path()
                        rule.move(to: CGPoint(x: 0, y: size.height - 1)); rule.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                        context.stroke(rule, with: .color(SiftChartStyle.rule), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        var line = Path()
                        for (index, sample) in recent.enumerated() {
                            if index == 0 { line.move(to: point(sample)) } else { line.addLine(to: point(sample)) }
                            if sample.cleanup {
                                let p = point(sample)
                                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(SiftChartStyle.accent))
                            }
                        }
                        context.stroke(line, with: .color(.primary.opacity(0.75)), lineWidth: 1.25)
                    }.frame(height: 40).accessibilityHidden(true)
                    VStack(alignment: .trailing) {
                        Text(ByteFormatting.string(high))
                        Spacer()
                        Text(ByteFormatting.string(low))
                    }.font(.system(size: 9).monospacedDigit()).foregroundStyle(SiftChartStyle.mutedText).frame(height: 40)
                }
                HStack {
                    Text(first.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    Spacer()
                    Text(last.date.formatted(.dateTime.hour().minute()))
                }.font(.system(size: 9).monospacedDigit()).foregroundStyle(SiftChartStyle.mutedText)
                Text("Scaled to shown range · orange dots mark cleanup attempts, not guaranteed savings")
                    .font(.system(size: 9)).foregroundStyle(SiftChartStyle.mutedText)
            } else {
                Text("History starts now. Samples are saved every 15 minutes while Sift runs.")
                    .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
            }
        }.padding(12).siftStorageSurface()
        .accessibilityElement(children: .combine)
    }
}

struct FolderGrowthView: View {
    let current: StorageMeasurement
    let previous: StorageMeasurement
    private var changes: [(folder: StorageFolder, delta: Int64)] {
        let old = Dictionary(uniqueKeysWithValues: previous.folders.map { ($0.path, $0) })
        let new = Dictionary(uniqueKeysWithValues: current.folders.map { ($0.path, $0) })
        return Set(old.keys).union(new.keys).compactMap { path -> (folder: StorageFolder, delta: Int64)? in
            guard let folder = new[path] ?? old[path] else { return nil }
            let delta = (new[path]?.bytes ?? 0) - (old[path]?.bytes ?? 0)
            return delta == 0 ? nil : (folder, delta)
        }.sorted { abs($0.delta) == abs($1.delta) ? $0.folder.path < $1.folder.path : abs($0.delta) > abs($1.delta) }.prefix(5).map { $0 }
    }
    var body: some View {
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("FOLDER SIZE CHANGES").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(SiftChartStyle.secondaryText)
                Text("\(previous.date.formatted(date: .abbreviated, time: .shortened)) → \(current.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                ForEach(changes, id: \.folder.path) { change in
                    HStack(spacing: 8) {
                        Text(change.folder.name).font(.caption).lineLimit(1).frame(width: 100, alignment: .leading)
                        HStack(spacing: 2) {
                            StorageBlockBar(fraction: change.delta < 0 ? Double(abs(change.delta)) / Double(max(1, changes.map { abs($0.delta) }.max() ?? 1)) : 0, cells: 10)
                                .scaleEffect(x: -1, y: 1)
                            Rectangle().fill(.primary.opacity(0.2)).frame(width: 1)
                            StorageBlockBar(fraction: change.delta > 0 ? Double(change.delta) / Double(max(1, changes.map { abs($0.delta) }.max() ?? 1)) : 0, accent: true, cells: 10)
                        }.frame(height: 9).accessibilityHidden(true)
                        Text("\(change.delta > 0 ? "+" : "−")\(ByteFormatting.string(abs(change.delta)))")
                            .font(.caption2.monospacedDigit()).frame(width: 64, alignment: .trailing)
                    }
                }
                Text("← Smaller · larger →  ·  attributed sizes, not measured cleanup savings")
                    .font(.system(size: 9)).foregroundStyle(SiftChartStyle.mutedText)
            }.padding(12).siftStorageSurface()
        }
    }
}

struct SiftQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.045), in: Capsule())
            .overlay { Capsule().strokeBorder(.primary.opacity(0.09), lineWidth: 0.5) }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}
