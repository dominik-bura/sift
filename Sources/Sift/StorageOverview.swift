import AppKit
import Foundation
import SwiftUI

struct StorageFolder: Identifiable, Codable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let bytes: Int64
    var limitedAccess: Bool? = nil
    var name: String {
        if path == NSHomeDirectory() { return "Your home folder" }
        if path == StorageOverviewService.rootPath { return "Data volume" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

struct StorageFile: Identifiable, Codable, Equatable, Sendable {
    static let sampleLimit = 100
    var id: String { path }
    let path: String
    /// File-attributed allocation, not exclusive extents or promised savings.
    let bytes: Int64
    let logicalBytes: Int64
    let shared: Bool
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct StorageMeasurement: Codable, Sendable {
    let path: String
    let folders: [StorageFolder]
    let totalBytes: Int64?
    let date: Date
    let limitedAccess: Bool
    let timedOut: Bool
    var cancelled: Bool? = nil
    var accounting: String? = nil
    var accountingScope: String? = nil
    var cached: Bool? = nil
    // Optional for backwards-compatible history and directory-only fallback scans.
    var largeFiles: [StorageFile]? = nil
    var fileCount: Int? = nil
    var isComplete: Bool { totalBytes != nil && !timedOut && cancelled != true }
    func comparable(to other: StorageMeasurement) -> Bool {
        (accounting ?? "du-allocated-v1") == (other.accounting ?? "du-allocated-v1") &&
        accountingScope == other.accountingScope
    }

    // du reports allocated folder sizes. They are not unique APFS extents or
    // guaranteed cleanup savings; a signed residual preserves over-counting.
    func volumeDifference(usedBytes: Int64) -> Int64? {
        guard let totalBytes, isComplete else { return nil }
        return usedBytes - totalBytes
    }
}

struct StorageOverviewService: Sendable {
    typealias NativeScan = @Sendable (String, CommandCancellation?, Bool, @escaping @Sendable (StorageScanProgress) -> Void) throws -> NativeStorageScanner.Result
    enum Engine { case du, native }
    static let rootPath = "/System/Volumes/Data"
    private let runner = SecureCommandRunner()
    private let nativeScan: NativeScan
    init(nativeScan: @escaping NativeScan = { path, cancellation, useCache, progress in
        try NativeStorageScanner(cache: useCache ? .shared : nil).measure(path: path, cancellation: cancellation, onProgress: progress)
    }) { self.nativeScan = nativeScan }

    static func scansOverlap(_ left: String, _ right: String) -> Bool {
        left == right || left == "/" || right == "/" || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    func measure(path: String, onProgress: @escaping @Sendable (StorageScanProgress) -> Void = { _ in }) -> StorageMeasurement {
        measureTree(path: path, onProgress: onProgress).measurement
    }

    func measureTree(path: String, cancellation: CommandCancellation? = nil, engine: Engine = .native, useCache: Bool = true, onProgress: @escaping @Sendable (StorageScanProgress) -> Void = { _ in }) -> (measurement: StorageMeasurement, children: [StorageMeasurement]) {
        if engine == .native, let result = try? nativeScan(path, cancellation, useCache, onProgress) {
            return (result.measurement, result.children)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let accumulator = StorageScanAccumulator(path: url.path)
        let result = runner.run(URL(fileURLWithPath: "/usr/bin/du"),
                                arguments: ["-x", "-k", url.path], timeout: 600,
                                captureOutput: false, onOutputLine: { accumulator.consume($0, onProgress: onProgress) }, cancellation: cancellation)
        let final = accumulator.snapshot()
        onProgress(final)
        let limited = result.exitCode != 0 || !result.error.isEmpty
        let measurement = StorageMeasurement(path: url.path, folders: final.folders, totalBytes: final.totalBytes,
                                             date: Date(), limitedAccess: limited, timedOut: result.timedOut, cancelled: result.cancelled)
        let children = final.children.map {
            StorageMeasurement(path: $0.path, folders: $0.folders, totalBytes: $0.totalBytes,
                               date: $0.date, limitedAccess: limited, timedOut: false)
        }
        return (measurement, children)
    }

    static func parse(_ result: CommandResult, path: String) -> StorageMeasurement {
        var total: Int64?
        var folders: [StorageFolder] = []
        for line in result.output.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"),
                  let kilobytes = Int64(line[..<tab]), kilobytes >= 0,
                  kilobytes <= Int64.max / 1024 else { continue }
            let child = String(line[line.index(after: tab)...])
            if child == path { total = kilobytes * 1024 }
            else if URL(fileURLWithPath: child).deletingLastPathComponent().path == path {
                folders.append(StorageFolder(path: child, bytes: kilobytes * 1024))
            }
        }
        return StorageMeasurement(path: path, folders: folders.sorted { $0.bytes > $1.bytes },
                                  totalBytes: total, date: Date(),
                                  limitedAccess: result.exitCode != 0 || !result.error.isEmpty,
                                  timedOut: result.timedOut, cancelled: result.cancelled)
    }
}

struct StorageHistoryStore {
    let url: URL
    init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.url = url ?? base.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "Sift")/storage-history.json")
    }
    func load() -> [String: StorageMeasurement] { loadArchive().latest }
    func loadArchive() -> StorageHistoryArchive {
        guard let data = try? Data(contentsOf: url) else { return StorageHistoryArchive() }
        if let archive = try? JSONDecoder().decode(StorageHistoryArchive.self, from: data) { return archive }
        // Migrate the earlier latest-measurement-only format without losing it.
        return StorageHistoryArchive(latest: (try? JSONDecoder().decode([String: StorageMeasurement].self, from: data)) ?? [:])
    }
    func save(_ measurements: [String: StorageMeasurement]) {
        var archive = loadArchive()
        archive.latest = measurements
        saveArchive(archive)
    }
    func saveArchive(_ archive: StorageHistoryArchive) {
        func recent(_ values: [String: StorageMeasurement]) -> [String: StorageMeasurement] {
            Dictionary(uniqueKeysWithValues: values.values.sorted { $0.date > $1.date }.prefix(100).map { ($0.path, $0) })
        }
        let records = archive.snapshots.values.flatMap { Array($0.filter { $0.isComplete && !$0.limitedAccess }.sorted { $0.date < $1.date }.suffix(64)) }
            .sorted { $0.date > $1.date }.prefix(512)
        let bounded = StorageHistoryArchive(latest: recent(archive.latest),
            snapshots: Dictionary(grouping: records, by: \.path).mapValues { $0.sorted { $0.date < $1.date } }, partial: recent(archive.partial))
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { }
    }
}

struct StorageHistoryArchive: Codable {
    var version = 1
    var latest: [String: StorageMeasurement] = [:]
    var snapshots: [String: [StorageMeasurement]] = [:]
    var partial: [String: StorageMeasurement] = [:]
}

typealias StorageMeasure = @Sendable (String, CommandCancellation, @escaping @Sendable (StorageScanProgress) -> Void) -> (measurement: StorageMeasurement, children: [StorageMeasurement])

@MainActor final class StorageOverviewModel: ObservableObject {
    @Published var location = StorageOverviewService.rootPath
    @Published private(set) var measurements: [String: StorageMeasurement]
    @Published private(set) var previous: [String: StorageMeasurement] = [:]
    @Published private(set) var scanningPaths = Set<String>()
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var progress: [String: StorageScanProgress] = [:]
    private let store: StorageHistoryStore
    private let measure: StorageMeasure
    @Published private(set) var queuedPaths: [String] = []
    @Published private(set) var cancellingPaths = Set<String>()
    @Published private(set) var partialMeasurements: [String: StorageMeasurement] = [:]
    @Published private(set) var snapshots: [String: [StorageMeasurement]] = [:]
    private var requestedAt: [String: Date] = [:]
    private var cancellations: [String: CommandCancellation] = [:]
    private var scanIDs: [String: UUID] = [:]
    private var independentScanRequests = Set<String>()
    init(store: StorageHistoryStore = StorageHistoryStore(), measure: @escaping StorageMeasure = { path, cancellation, progress in
        StorageOverviewService().measureTree(path: path, cancellation: cancellation, onProgress: progress)
    }) {
        self.store = store
        self.measure = measure
        let archive = store.loadArchive()
        measurements = archive.latest
        snapshots = archive.snapshots
        partialMeasurements = archive.partial
        for measurement in measurements.values { recordSnapshot(measurement) }
    }

    func growthBaseline(for path: String) -> StorageMeasurement? {
        guard let current = measurements[path], current.isComplete, !current.limitedAccess else { return nil }
        let older = (snapshots[path] ?? []).filter { $0.path == path && $0.isComplete && !$0.limitedAccess && $0.date < current.date && $0.comparable(to: current) }.sorted { $0.date < $1.date }
        let weekAgo = current.date.addingTimeInterval(-7 * 86_400)
        return older.last(where: { $0.date <= weekAgo }) ?? older.first
    }

    private func recordSnapshot(_ measurement: StorageMeasurement) {
        guard measurement.isComplete, !measurement.limitedAccess else { return }
        var history = snapshots[measurement.path] ?? []
        guard !history.contains(where: { $0.date == measurement.date }) else { return }
        history.append(measurement)
        history.sort { $0.date < $1.date }
        // Keep the first and latest sample of each day, rather than letting
        // repeated refreshes displace all longer-term comparisons.
        let days = Dictionary(grouping: history) { Calendar.current.startOfDay(for: $0.date) }
        history = days.values.flatMap { values -> [StorageMeasurement] in
            guard let first = values.first, let last = values.last else { return [] }
            return first.date == last.date ? [first] : [first, last]
        }.sorted { $0.date < $1.date }
        snapshots[measurement.path] = Array(history.suffix(64))
    }

    func cancel(_ path: String) {
        if queuedPaths.contains(path) {
            queuedPaths.removeAll { $0 == path }
            requestedAt[path] = nil
            independentScanRequests.remove(path)
            errors[path] = "Queued scan cancelled. Saved results are unchanged."
        } else if let cancellation = cancellations[path] {
            cancellingPaths.insert(path)
            cancellation.cancel()
        }
    }

    func scanCurrentFolder(fullRescan: Bool = false) {
        scan(location, force: true, fullRescan: fullRescan, discoverFiles: true)
    }

    func scan(_ path: String, force: Bool = false, fullRescan: Bool = false, discoverFiles: Bool = false) {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if queuedPaths.contains(path) {
            if discoverFiles || fullRescan { independentScanRequests.insert(path) }
            if fullRescan { NativeScanCache.shared.invalidate(path) }
            return
        }
        guard !scanningPaths.contains(path) else { return }
        // Saved history alone does not prove freshness. Only the native
        // session cache, with a continuous event lease, may skip a disk walk.
        if fullRescan { NativeScanCache.shared.invalidate(path) }
        guard queuedPaths.count < 20 else { errors[path] = "Scan queue is full. Wait for a scan to finish."; return }
        if discoverFiles || fullRescan { independentScanRequests.insert(path) }
        requestedAt[path] = Date()
        errors[path] = nil
        queuedPaths.append(path)
        // A single disk walk avoids competing recursive reads. Prefer known
        // smaller folders among waiting requests; whole-volume scans go last.
        queuedPaths.sort {
            if ($0 == StorageOverviewService.rootPath) != ($1 == StorageOverviewService.rootPath) { return $1 == StorageOverviewService.rootPath }
            let a = measurements[$0]?.totalBytes ?? Int64.max
            let b = measurements[$1]?.totalBytes ?? Int64.max
            return a == b ? requestedAt[$0]! < requestedAt[$1]! : a < b
        }
        startNext()
    }

    private func startNext() {
        guard scanningPaths.isEmpty, let path = queuedPaths.first else { return }
        queuedPaths.removeFirst()
        let requiresOwnWalk = independentScanRequests.remove(path) != nil
        let requested = requestedAt.removeValue(forKey: path) ?? Date()
        // A preceding parent scan may already have measured this subtree.
        if !requiresOwnWalk, let saved = measurements[path], saved.isComplete, !saved.limitedAccess, saved.date >= requested {
            startNext()
            return
        }
        scanningPaths.insert(path)
        let scanID = UUID()
        scanIDs[path] = scanID
        errors[path] = nil
        progress[path] = StorageScanProgress(path: path, startedAt: Date(), completedDirectories: 0,
                                             currentPath: nil, folders: [], children: [], totalBytes: nil)
        let cancellation = CommandCancellation()
        cancellations[path] = cancellation
        let measure = self.measure
        Task { [self] in
            let outcome = await Task.detached(priority: .utility) {
                measure(path, cancellation) { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanIDs[path] == scanID, self.scanningPaths.contains(path),
                              update.completedDirectories >= (self.progress[path]?.completedDirectories ?? 0) else { return }
                        self.progress[path] = update
                        for child in update.children where !self.scanningPaths.contains(child.path) {
                            // Completed subtrees are immediately available for drill-down.
                            if self.measurements[child.path] == nil || (!child.limitedAccess && (self.measurements[child.path]?.date ?? .distantPast) < update.startedAt) {
                                self.measurements[child.path] = child
                            }
                        }
                    }
                }
            }.value
            let result = outcome.measurement
            for child in outcome.children where !scanningPaths.contains(child.path) {
                if measurements[child.path] == nil || (!child.limitedAccess && (measurements[child.path]?.date ?? .distantPast) <= child.date) {
                    measurements[child.path] = child
                    recordSnapshot(child)
                }
            }
            if result.isComplete {
                previous[path] = measurements[path]
                measurements[path] = result
                partialMeasurements[path] = nil
                recordSnapshot(result)
            } else {
                errors[path] = result.cancelled == true ? "Scan cancelled. Completed rows are retained; unmeasured rows may show earlier values." : result.timedOut ? "Refresh timed out. Completed rows are retained; try scanning a smaller folder." : "The folder could not be measured. Check its permissions."
                let finalProgress = StorageScanProgress(path: path, startedAt: result.date, completedDirectories: 0,
                    currentPath: nil, folders: result.folders, children: [], totalBytes: nil,
                    largeFiles: result.largeFiles, fileCount: result.fileCount)
                let merged = finalProgress.displaying(over: progress[path]?.displaying(over: measurements[path]) ?? measurements[path])
                partialMeasurements[path] = StorageMeasurement(path: path, folders: merged.folders,
                    totalBytes: nil, date: result.date, limitedAccess: true, timedOut: result.timedOut, cancelled: result.cancelled,
                    largeFiles: merged.largeFiles, fileCount: merged.fileCount)
            }
            scanningPaths.remove(path)
            scanIDs[path] = nil
            progress[path] = nil
            cancellations[path] = nil
            cancellingPaths.remove(path)
            store.saveArchive(StorageHistoryArchive(latest: measurements, snapshots: snapshots, partial: partialMeasurements))
            startNext()
        }
    }
}


struct StorageScanPrompt: View {
    let path: String
    let onScan: () -> Void
    private var isVolume: Bool { path == StorageOverviewService.rootPath }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.magnifyingglass")
                    .font(.title2).foregroundStyle(SiftChartStyle.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not scanning").font(.callout.weight(.semibold))
                    Text("Start a scan to see which folders use space.")
                        .font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
                }
            }
            Text(isVolume
                 ? "Scan the data volume, or choose Home folder or App data above for a narrower scan."
                 : "Scan this folder and its subfolders. Results appear as each folder finishes.")
                .font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
            Button(isVolume ? "Scan data volume" : "Scan this folder", action: onScan)
                .buttonStyle(.borderedProminent).tint(SiftChartStyle.accent).controlSize(.regular)
            Text("Read-only · starts only when you ask. macOS may request folder access; you can deny it and still see partial results.")
                .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).siftStorageSurface()
    }
}

extension View {
    func siftStorageSurface() -> some View { self.modifier(StorageSurface()) }
}
private struct StorageSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26, *) {
                // Glass is a background here, not a control that should switch
                // its content to a contrasting appearance based on the backdrop.
                content.background {
                    RoundedRectangle(cornerRadius: 14).fill(.clear)
                        .glassEffect(.clear.tint(colorScheme == .dark ? .black.opacity(0.18) : .white.opacity(0.10)), in: .rect(cornerRadius: 14))
                        // Attenuate only the glass background, never the text
                        // or controls. Tint alone left too much gray luminance.
                        .opacity(colorScheme == .dark ? 0.32 : 0.55)
                        .allowsHitTesting(false)
                }
            }
            else { content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)) }
        }
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(SiftChartStyle.rule, lineWidth: 0.5).allowsHitTesting(false) }
    }
}
