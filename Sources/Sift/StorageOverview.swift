import AppKit
import Foundation
import SwiftUI

struct StorageFolder: Identifiable, Codable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let bytes: Int64
    var name: String {
        if path == NSHomeDirectory() { return "Your home folder" }
        if path == StorageOverviewService.rootPath { return "Data volume" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

struct StorageMeasurement: Codable, Sendable {
    let path: String
    let folders: [StorageFolder]
    let totalBytes: Int64?
    let date: Date
    let limitedAccess: Bool
    let timedOut: Bool

    // du reports allocated folder sizes. They are not unique APFS extents or
    // guaranteed cleanup savings; a signed residual preserves over-counting.
    func volumeDifference(usedBytes: Int64) -> Int64? {
        guard let totalBytes, !timedOut else { return nil }
        return usedBytes - totalBytes
    }
}

struct StorageOverviewService: Sendable {
    static let rootPath = "/System/Volumes/Data"
    private let runner = SecureCommandRunner()

    func measure(path: String) -> StorageMeasurement {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let result = runner.run(URL(fileURLWithPath: "/usr/bin/du"),
                                arguments: ["-x", "-k", "-d", "1", url.path], timeout: 600)
        return Self.parse(result, path: url.path)
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
                                  timedOut: result.timedOut)
    }
}

struct StorageHistoryStore {
    let url: URL
    init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.url = url ?? base.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "Sift")/storage-history.json")
    }
    func load() -> [String: StorageMeasurement] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: StorageMeasurement].self, from: data) else { return [:] }
        return saved
    }
    func save(_ measurements: [String: StorageMeasurement]) {
        let recent = measurements.values.sorted { $0.date > $1.date }.prefix(100)
        guard let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: recent.map { ($0.path, $0) })) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { }
    }
}

@MainActor final class StorageOverviewModel: ObservableObject {
    @Published private(set) var measurements: [String: StorageMeasurement]
    @Published private(set) var previous: [String: StorageMeasurement] = [:]
    @Published private(set) var scanningPaths = Set<String>()
    @Published private(set) var errors: [String: String] = [:]
    private let store = StorageHistoryStore()
    init() { measurements = store.load() }

    func scan(_ path: String, force: Bool = false) {
        guard !scanningPaths.contains(path) else { return }
        if !force, let saved = measurements[path], Date().timeIntervalSince(saved.date) < 21_600 { return }
        // Limit expensive directory walks, independent of popover lifetime.
        guard scanningPaths.count < 2 else { return }
        scanningPaths.insert(path)
        errors[path] = nil
        let service = StorageOverviewService()
        Task {
            let result = await Task.detached(priority: .utility) { service.measure(path: path) }.value
            if !result.timedOut, result.totalBytes != nil {
                previous[path] = measurements[path]
                measurements[path] = result
                store.save(measurements)
            } else {
                errors[path] = result.timedOut ? "Refresh timed out. Earlier results, if shown, remain unchanged." : "The folder could not be measured. Check its permissions."
                if measurements[path] == nil { measurements[path] = result }
            }
            scanningPaths.remove(path)
        }
    }
}

struct StorageOverviewView: View {
    @ObservedObject var overview: StorageOverviewModel
    @EnvironmentObject private var app: AppModel
    @State private var navigation = [StorageOverviewService.rootPath]
    private var path: String { navigation.last! }
    private var measurement: StorageMeasurement? { overview.measurements[path] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if navigation.count > 1 {
                    Button { navigation.removeLast() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).help("Parent folder")
                }
                Text(path == StorageOverviewService.rootPath ? "WHERE IS MY STORAGE?" : URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Button { overview.scan(path, force: true) } label: {
                    if overview.scanningPaths.contains(path) { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(.plain).disabled(overview.scanningPaths.contains(path) || overview.scanningPaths.count >= 2)
                    .help("Refresh folder sizes")
            }
            if path == StorageOverviewService.rootPath {
                HStack {
                    Button("Home folder") { navigation.append(NSHomeDirectory()); overview.scan(NSHomeDirectory()) }
                    Button("App data") { let folder = NSHomeDirectory() + "/Library"; navigation.append(folder); overview.scan(folder) }
                }.controlSize(.small)
            }
            if overview.scanningPaths.contains(path) {
                Label("Measuring folders in the background…", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Large folders can take several minutes. You can close this menu; the scan continues.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = overview.errors[path] { Text(error).font(.caption).foregroundStyle(.orange) }
            if let measurement {
                Text("\(measurement.limitedAccess ? "Limited access" : "Readable folders measured") · \(measurement.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    .font(.caption2).foregroundStyle(.secondary)
                if measurement.timedOut {
                    Text("The scan timed out. These results are incomplete; try scanning a smaller folder.")
                        .font(.caption).foregroundStyle(.orange)
                }
                VStack(spacing: 0) {
                    ForEach(measurement.folders) { folder in
                        HStack(spacing: 10) {
                            Button {
                                navigation.append(folder.path)
                                overview.scan(folder.path)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(folder.name).font(.callout.weight(.medium))
                                        if let old = overview.previous[path],
                                           let prior = old.folders.first(where: { $0.path == folder.path }) {
                                            let delta = folder.bytes - prior.bytes
                                            if delta != 0 {
                                                Text("\(delta > 0 ? "+" : "−")\(ByteFormatting.string(abs(delta))) since previous scan")
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    Spacer()
                                    Text(ByteFormatting.string(folder.bytes)).font(.caption.monospacedDigit())
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)]) } label: {
                                Image(systemName: "arrow.up.forward.square")
                            }.buttonStyle(.plain).help("Reveal \(folder.name) in Finder")
                        }.padding(.vertical, 11).padding(.horizontal, 12)
                        if folder.id != measurement.folders.last?.id { Divider().padding(.horizontal, 12) }
                    }
                }.siftStorageSurface()
                if let total = measurement.totalBytes {
                    let directFiles = total - measurement.folders.reduce(0) { $0 + $1.bytes }
                    if directFiles > 0 {
                        HStack { Text("Files directly in this folder"); Spacer(); Text(ByteFormatting.string(directFiles)).monospacedDigit() }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if path == StorageOverviewService.rootPath, let capacity = app.diskCapacity(), let free = app.freeDiskSpace(),
                   let difference = measurement.volumeDifference(usedBytes: capacity - free) {
                    HStack {
                        Text("Volume accounting difference")
                        Spacer()
                        Text("\(difference < 0 ? "−" : "")\(ByteFormatting.string(abs(difference)))").monospacedDigit()
                    }.font(.caption)
                    Text("Protected files, other APFS volumes, metadata, and shared blocks can cause this difference. It is not a cleanup target.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if overview.previous[path] == nil {
                    Text("Growth comparisons appear after the next successful scan of this folder.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if overview.previous[path] != nil, measurement.limitedAccess {
                    Text("Growth comparisons are approximate when access is limited or permissions change.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if !overview.scanningPaths.contains(path) {
                Button("Measure this folder") { overview.scan(path, force: true) }
            }
            Text("Read-only view. Folder sizes include personal files and may share APFS blocks; they are not guaranteed cleanup savings.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { overview.scan(path) }
    }
}

extension View {
    func siftStorageSurface() -> some View { self.modifier(StorageSurface()) }
}
private struct StorageSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.glassEffect(.regular, in: .rect(cornerRadius: 14)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
    }
}
