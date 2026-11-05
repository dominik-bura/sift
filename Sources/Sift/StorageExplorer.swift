import AppKit
import Foundation
import SwiftUI

enum StorageExplorerSort: String, CaseIterable {
    case size = "Largest first", growth = "Most growth", name = "Name"
}

enum StorageExplorerResults {
    static let fileLimit = StorageFile.sampleLimit

    static func folders(_ measurement: StorageMeasurement, query: String, sort: StorageExplorerSort,
                        baseline: StorageMeasurement?) -> [StorageFolder] {
        let previous = Dictionary((baseline?.folders ?? []).map { ($0.path, $0.bytes) }, uniquingKeysWith: { _, new in new })
        let canCompare = measurement.isComplete && !measurement.limitedAccess && baseline?.isComplete == true &&
            baseline?.limitedAccess == false && baseline.map { measurement.comparable(to: $0) } == true
        return measurement.folders.filter { matches($0.path, query: query) }.sorted {
            if sort == .name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if sort == .growth, canCompare {
                let a = $0.bytes - (previous[$0.path] ?? 0), b = $1.bytes - (previous[$1.path] ?? 0)
                if a != b { return a > b }
            }
            return $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
        }
    }

    static func files(_ measurement: StorageMeasurement, query: String, sort: StorageExplorerSort) -> [StorageFile] {
        (measurement.largeFiles ?? []).filter { matches($0.path, query: query) }.sorted {
            if sort == .name { return $0.name == $1.name ? $0.path < $1.path : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
        }
    }

    static func matches(_ path: String, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { path.localizedStandardContains(String($0)) }
    }

    /// Lexical normalization only: classification must not follow an arbitrary
    /// symlink and accidentally present an unknown path as a cleanup target.
    static func canonical(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = StorageOverviewService.rootPath
        if path == root { return "/" }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count)) : path
    }

    static func contains(_ root: String, _ path: String) -> Bool {
        let root = canonical(root), path = canonical(path)
        return root == path || (root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/"))
    }

    static func breadcrumbs(_ path: String) -> [StorageBreadcrumb] {
        let root = StorageOverviewService.rootPath
        guard path != root, path != "/" else { return [.init(path: root, name: "Data")] }
        let components = canonical(path).split(separator: "/")
        let dataPrefix = path.hasPrefix(root + "/") ? root : ""
        var result = [StorageBreadcrumb(path: root, name: "Data")]
        var ancestor = dataPrefix
        for component in components {
            ancestor += "/" + component
            result.append(.init(path: ancestor, name: String(component)))
        }
        return result
    }

    static func fraction(bytes: Int64, maximum: Int64) -> Double {
        guard maximum > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(maximum)))
    }
}

struct StorageBreadcrumb: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
}

struct StorageCleanupTarget: Equatable {
    enum Kind: Equatable { case cache(String), workspace(String) }
    let kind: Kind
    let name: String
    let path: String
    var scopeDescription: String {
        switch kind {
        case .cache: return "Review covers the complete supported cache, not just this row."
        case .workspace: return "Review covers generated folders only; source files and project roots stay protected."
        }
    }
}

struct StoragePathContext {
    let label: String
    let target: StorageCleanupTarget?
    var color: Color {
        switch label {
        case "Known cache": return SiftChartStyle.inventoryColor(for: CacheCategory.packages.id)
        case "Generated data", "Project · generated folders": return SiftChartStyle.inventoryColor(for: "worktrees")
        case "Personal data": return SiftChartStyle.inventoryColor(for: CacheCategory.apps.id)
        default: return SiftChartStyle.mutedText
        }
    }

    static func classify(_ path: String, caches: [GlobalCache], workspaces: [Workspace], home: String = NSHomeDirectory()) -> Self {
        // Only current, explicitly supported cleanup targets get a handoff.
        // A folder called 'cache' or 'node_modules' alone is not authorization.
        let cache = caches.filter { cache in
            cache.state.path.map { StorageExplorerResults.contains($0, path) } ?? false
        }.max { ($0.state.path?.count ?? 0) < ($1.state.path?.count ?? 0) }
        if let cache, let cachePath = cache.state.path {
            return Self(label: "Known cache", target: StorageCleanupTarget(kind: .cache(cache.id), name: cache.name, path: cachePath))
        }
        if let workspace = workspaces.first(where: { workspace in
            StorageExplorerResults.canonical(workspace.url.path) == StorageExplorerResults.canonical(path) ||
                workspace.candidates.contains { StorageExplorerResults.contains($0.url.path, path) }
        }), !workspace.candidates.isEmpty {
            let isRoot = StorageExplorerResults.canonical(workspace.url.path) == StorageExplorerResults.canonical(path)
            return Self(label: isRoot ? "Project · generated folders" : "Generated data", target: StorageCleanupTarget(kind: .workspace(workspace.id), name: workspace.name, path: workspace.url.path))
        }
        let personal = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
            .contains { StorageExplorerResults.contains(home + "/" + $0, path) }
        return Self(label: personal ? "Personal data" : "Needs review", target: nil)
    }
}

struct StorageExplorerRefreshButton: View {
    @ObservedObject var overview: StorageOverviewModel
    var disabled = false
    private var path: String { overview.location }
    var body: some View {
        Button { overview.scanCurrentFolder() } label: {
            if overview.scanningPaths.contains(path) { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.clockwise").font(.system(size: 15)) }
        }.buttonStyle(.plain).foregroundStyle(SiftChartStyle.secondaryText)
            .disabled(disabled || overview.scanningPaths.contains(path) || overview.queuedPaths.contains(path))
            .help("Scan \(path)").accessibilityLabel("Scan current folder")
            .contextMenu { Button("Full rescan of this folder (ignore cache)") { overview.scanCurrentFolder(fullRescan: true) } }
    }
}

struct StorageExplorerView: View {
    @ObservedObject var overview: StorageOverviewModel
    @EnvironmentObject private var app: AppModel
    var onReviewCleanup: (StorageCleanupTarget) -> Void = { _ in }
    @State private var query = ""
    @State private var filesMode = false
    @State private var sort: StorageExplorerSort = .size
    init(overview: StorageOverviewModel, onReviewCleanup: @escaping (StorageCleanupTarget) -> Void = { _ in }, showingFiles: Bool = false) {
        self.overview = overview
        self.onReviewCleanup = onReviewCleanup
        _filesMode = State(initialValue: showingFiles)
    }
    private var path: String { overview.location }
    private var busy: Bool { overview.scanningPaths.contains(path) || overview.queuedPaths.contains(path) }
    private var measurement: StorageMeasurement? {
        overview.progress[path]?.displaying(over: overview.measurements[path]) ?? overview.partialMeasurements[path] ?? overview.measurements[path]
    }
    private var baseline: StorageMeasurement? { overview.growthBaseline(for: path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            explorerHeader
            breadcrumbs
            if path == StorageOverviewService.rootPath {
                HStack {
                    Button("Home folder") { overview.location = NSHomeDirectory() }
                    Button("App data") { overview.location = NSHomeDirectory() + "/Library" }
                }.buttonStyle(SiftQuietButtonStyle())
            }
            if let position = overview.queuedPaths.firstIndex(of: path) {
                Text("Queued · \(position + 1) in line. One folder scan runs at a time.")
                    .font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
            }
            if let progress = overview.progress[path] { progressView(progress) }
            if let error = overview.errors[path] { Text(error).font(.caption).foregroundStyle(.orange) }
            if let measurement {
                results(measurement)
            } else if !busy {
                StorageScanPrompt(path: path) { overview.scanCurrentFolder() }
            }
            Text("Read-only exploration · sizes may share APFS blocks and are not guaranteed cleanup savings.")
                .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
        }
        .onChange(of: path) { _, _ in query = "" }
    }

    private var explorerHeader: some View {
        HStack {
            Text("WHERE IS MY STORAGE?").font(.caption.weight(.semibold))
            Spacer()
            if busy {
                Button(overview.cancellingPaths.contains(path) ? "Stopping…" : "Cancel") { overview.cancel(path) }
                    .buttonStyle(SiftQuietButtonStyle()).disabled(overview.cancellingPaths.contains(path))
            }
            StorageExplorerRefreshButton(overview: overview, disabled: app.isCleaning)
        }
    }

    private var breadcrumbs: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    if let parent = StorageExplorerResults.breadcrumbs(path).dropLast().last { overview.location = parent.path }
                } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).disabled(path == StorageOverviewService.rootPath)
                    .keyboardShortcut("[", modifiers: .command).help("Parent folder")
                ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(StorageExplorerResults.breadcrumbs(path)) { crumb in
                        if crumb.path != StorageOverviewService.rootPath {
                            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(SiftChartStyle.mutedText)
                        }
                        Button(crumb.name) { overview.location = crumb.path }
                            .buttonStyle(.plain).font(.caption.weight(crumb.path == path ? .semibold : .regular))
                            .foregroundStyle(crumb.path == path ? Color.primary : SiftChartStyle.secondaryText)
                            .help(crumb.path).id(crumb.path)
                    }
                }.padding(.vertical, 2)
                }.scrollIndicators(.hidden)
                    .onAppear { scroll.scrollTo(path, anchor: .trailing) }
                    .onChange(of: path) { _, value in scroll.scrollTo(value, anchor: .trailing) }
                }
            }
            HStack(spacing: 6) {
                Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { reveal(path) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.plain).help("Reveal current folder in Finder").accessibilityLabel("Reveal current folder in Finder")
            }.font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
        }
    }

    private func progressView(_ progress: StorageScanProgress) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(progress.completedDirectories) folders measured").monospacedDigit()
                    Spacer()
                    Text("\(Int(max(0, context.date.timeIntervalSince(progress.startedAt))))s elapsed").monospacedDigit()
                }
                if let current = progress.currentPath { Text(current).lineLimit(1).truncationMode(.middle) }
                Text("Intermediate results · continues when you close this menu.")
            }.font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
        }
    }

    private func results(_ measurement: StorageMeasurement) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(status(measurement)).lineLimit(2)
                Spacer(minLength: 4)
                if let total = measurement.totalBytes {
                    Text("\(measurement.limitedAccess ? "≥ " : "")\(ByteFormatting.string(total))").monospacedDigit()
                }
            }.font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
            if measurement.timedOut {
                Text("Scan timed out. Results are incomplete; try a smaller folder.").font(.caption).foregroundStyle(.orange)
            }
            resultControls
            if filesMode { fileResults(measurement) } else { folderResults(measurement) }
            if !filesMode, overview.progress[path] == nil, let baseline,
               measurement.isComplete, !measurement.limitedAccess {
                FolderGrowthView(current: measurement, previous: baseline)
            }
            accounting(measurement)
        }
    }

    private var resultControls: some View {
        VStack(spacing: 8) {
            HStack {
                FullWidthSegmentedControl(labels: ["Folders", "Largest files"], selection: Binding(
                    get: { filesMode ? 1 : 0 }, set: { filesMode = $0 == 1 }
                ), accessibilityLabel: "Storage result type").frame(maxWidth: 230)
                Spacer(minLength: 4)
                Menu {
                    Picker("Sort results", selection: $sort) {
                        ForEach(StorageExplorerSort.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                                .disabled(option == .growth && (filesMode || baseline == nil || measurement?.isComplete != true || measurement?.limitedAccess == true))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(effectiveSort.rawValue).font(.caption2)
                        Image(systemName: "arrow.up.arrow.down").font(.caption2)
                    }
                }
                    .menuStyle(.borderlessButton).fixedSize().help("Sort: \(effectiveSort.rawValue)")
                    .accessibilityLabel("Sort results: \(effectiveSort.rawValue)")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(SiftChartStyle.mutedText)
                TextField(filesMode ? "Filter discovered files by name or path" : "Filter measured folders by name or path", text: $query)
                    .textFieldStyle(.plain).font(.caption).accessibilityLabel("Filter measured results")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear filter")
                }
            }.padding(8).siftStorageSurface()
        }
    }

    private var effectiveSort: StorageExplorerSort {
        sort == .growth && (filesMode || baseline == nil || measurement?.isComplete != true || measurement?.limitedAccess == true) ? .size : sort
    }

    private func folderResults(_ measurement: StorageMeasurement) -> some View {
        let rows = StorageExplorerResults.folders(measurement, query: query, sort: effectiveSort, baseline: baseline)
        let maximum = measurement.folders.map(\.bytes).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(rows.count) of \(measurement.folders.count) folders · bars relative to largest folder")
                .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
            if rows.isEmpty {
                emptyResults(query.isEmpty ? "No readable subfolders found. Check Largest files for files stored here." : "No measured folders match this filter.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { folder in
                        explorerRow(path: folder.path, name: folder.name, bytes: folder.bytes, maximum: maximum,
                            limited: folder.limitedAccess == true, isFile: false,
                            detail: growthDetail(folder, measurement: measurement), shared: false)
                        if folder.id != rows.last?.id { Divider().padding(.horizontal, 12) }
                    }
                }.siftStorageSurface()
            }
        }
    }

    private func fileResults(_ measurement: StorageMeasurement) -> some View {
        let rows = StorageExplorerResults.files(measurement, query: query, sort: effectiveSort)
        let maximum = measurement.largeFiles?.map(\.bytes).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            if measurement.largeFiles == nil {
                emptyResults("This scan contains folders only. Scan this folder to discover files; discovery needs supported native APFS metadata and is unavailable in the directory-only fallback.")
                if !busy { Button("Scan this folder for files") { overview.scanCurrentFolder() }.buttonStyle(SiftQuietButtonStyle()) }
            } else {
                Text("Largest \(measurement.largeFiles?.count ?? 0) of \(measurement.fileCount ?? 0) files encountered · includes subfolders\(query.isEmpty ? "" : " · \(rows.count) matches")")
                    .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
                Text("File allocations may overlap each other and folder totals. Shared files are not exclusive savings; bars compare file sizes.")
                    .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                if rows.isEmpty {
                    emptyResults(query.isEmpty ? "No regular files found in the readable part of this scan." : "No files in the largest-\(StorageExplorerResults.fileLimit) sample match. Scan a narrower folder to discover more.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { file in
                            explorerRow(path: file.path, name: file.name, bytes: file.bytes, maximum: maximum,
                                limited: false, isFile: true,
                                detail: "\(file.shared ? "Shared · " : "")\(ByteFormatting.string(file.logicalBytes)) logical · \(relative(file.path))", shared: file.shared)
                            if file.id != rows.last?.id { Divider().padding(.horizontal, 12) }
                        }
                    }.siftStorageSurface()
                }
            }
        }
    }

    private func explorerRow(path rowPath: String, name: String, bytes: Int64, maximum: Int64,
                             limited: Bool, isFile: Bool, detail: String?, shared: Bool) -> some View {
        let context = StoragePathContext.classify(rowPath, caches: app.globalCaches, workspaces: app.workspaces)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if isFile { reveal(rowPath) } else { overview.location = rowPath }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            if let detail { Text(detail).font(.caption2).foregroundStyle(SiftChartStyle.secondaryText).lineLimit(1).truncationMode(.middle) }
                        }
                        Spacer(minLength: 2)
                        Text(limited ? (bytes > 0 ? "≥ \(ByteFormatting.string(bytes))" : "Unavailable") : ByteFormatting.string(bytes))
                            .font(.caption.monospacedDigit())
                        Image(systemName: isFile ? "arrow.up.forward.square" : "chevron.right")
                            .font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(isFile ? "Reveal in Finder · does not open or delete the file" : "Explore folder")
                Menu {
                    Button("Reveal in Finder") { reveal(rowPath) }
                    Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rowPath, forType: .string) }
                    if !isFile { Button("Scan this folder") { overview.location = rowPath; overview.scanCurrentFolder() } }
                    if let target = context.target { Button("Review \(target.name) cleanup…") { onReviewCleanup(target) } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(name)")
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.05))
                    RoundedRectangle(cornerRadius: 2).fill(context.color.opacity(shared || limited ? 0.5 : 0.8))
                        .frame(width: geometry.size.width * StorageExplorerResults.fraction(bytes: bytes, maximum: maximum))
                }
            }.frame(height: 4).accessibilityHidden(true).allowsHitTesting(false)
            HStack(spacing: 5) {
                Circle().fill(context.color).frame(width: 4, height: 4)
                Text(context.label)
                if limited { Text("· limited access") }
                Spacer()
                if let target = context.target {
                    Button("Review cleanup…") { onReviewCleanup(target) }
                        .buttonStyle(.plain).foregroundStyle(SiftChartStyle.accent)
                        .help("\(target.scopeDescription) \(target.path). Nothing is selected or deleted automatically.")
                }
            }.font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
        }.padding(12)
    }

    private func emptyResults(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(SiftChartStyle.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).siftStorageSurface()
    }

    private func growthDetail(_ folder: StorageFolder, measurement: StorageMeasurement) -> String? {
        guard overview.progress[path] == nil, measurement.isComplete, !measurement.limitedAccess, let baseline else { return nil }
        let prior = baseline.folders.first { $0.path == folder.path }?.bytes ?? 0
        let delta = folder.bytes - prior
        guard delta != 0 else { return nil }
        return "\(delta > 0 ? "+" : "−")\(ByteFormatting.string(abs(delta))) since \(baseline.date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func status(_ measurement: StorageMeasurement) -> String {
        let state = overview.progress[path] != nil ? "Live · earlier folder rows retained" :
            measurement.cancelled == true ? "Cancelled · incomplete" : measurement.limitedAccess ? "Limited access · partial results" :
            measurement.cached == true ? "Validated cached measurement" : "Readable folders measured"
        return "\(state) · \(measurement.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }

    @ViewBuilder private func accounting(_ measurement: StorageMeasurement) -> some View {
        if let total = measurement.totalBytes {
            let directFiles = max(0, total - measurement.folders.reduce(0) { $0 + $1.bytes })
            if directFiles > 0 {
                HStack { Text("Files & metadata directly here"); Spacer(); Text(ByteFormatting.string(directFiles)).monospacedDigit() }
                    .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
            }
        }
        if path == StorageOverviewService.rootPath, let capacity = app.diskCapacity(), let free = app.freeDiskSpace(),
           let difference = measurement.volumeDifference(usedBytes: capacity - free) {
            DisclosureGroup {
                Text("Protected files, other APFS volumes, metadata, and shared blocks can cause this difference. It is not a cleanup target.")
                    .font(.caption2).foregroundStyle(SiftChartStyle.secondaryText)
            } label: {
                HStack {
                    Text("Volume accounting difference")
                    Spacer()
                    Text("\(difference < 0 ? "−" : "")\(ByteFormatting.string(abs(difference)))").monospacedDigit()
                }.font(.caption2)
            }
        }
        if overview.progress[path] == nil, baseline == nil {
            Text("Scan this folder again later to compare growth.").font(.caption2).foregroundStyle(SiftChartStyle.mutedText)
        }
    }

    private func relative(_ file: String) -> String {
        let prefix = path == "/" ? "/" : path + "/"
        return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file
    }
    private func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
