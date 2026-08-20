import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var dockerState: DockerState = .checking
    @Published var globalCaches: [GlobalCache] = []
    @Published var selectedCandidateIDs = Set<String>()
    @Published var isScanning = false
    @Published var isBackgroundRefreshing = false
    @Published var scannedWorkspaceCount = 0
    @Published var discoveredWorkspaceCount = 0
    @Published var reusedCandidateSizeCount = 0
    @Published var measuredCandidateSizeCount = 0
    @Published var lastScanDuration: TimeInterval?
    @Published var isCleaning = false
    @Published private(set) var cleaningGlobalCacheID: String?
    @Published var lastMessage: String?
    @Published var lastSyncedAt: Date?
    @Published var searchRoots: [URL]
    @Published var updateState: UpdateState = .idle
    @Published private(set) var availableDiskBytes: Int64?
    @Published private(set) var totalDiskBytes: Int64?
    @Published private(set) var lastTrashedURLs: [URL] = []

    private let scanner = WorkspaceScanner()
    private let cleaner = CleanupService()
    private let docker = DockerService()
    private let globalCacheService = GlobalCacheService()
    private let scanCache = ScanCache()
    private let updateService = UpdateService()
    private let defaultsKey = "searchRoots"
    private let lastSyncedKey = "lastSuccessfulScanDate"

    init() {
        if Bundle.main.bundleIdentifier == "com.dominikbura.sift" {
            Self.migrateLegacyDefaultsIfNeeded()
        }
        let defaults = Self.defaultSearchRoots()
        if let stored = UserDefaults.standard.stringArray(forKey: defaultsKey), !stored.isEmpty {
            let combined = stored.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL } + defaults
            searchRoots = Array(Dictionary(grouping: combined, by: \.path).compactMap(\.value.first))
        } else {
            searchRoots = defaults
        }
        workspaces = scanCache.load(under: searchRoots)
        globalCaches = globalCacheService.installedPlaceholders()
        lastSyncedAt = UserDefaults.standard.object(forKey: lastSyncedKey) as? Date
        refreshDiskSpace()
        if updateService.repository == nil {
            updateState = .unavailable
        } else {
            Task { [weak self] in
                await self?.checkForUpdates()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(21_600))
                    guard !Task.isCancelled else { break }
                    await self?.checkForUpdates()
                }
            }
        }
    }

    var candidates: [CleanupCandidate] { workspaces.flatMap(\.candidates) }
    var selectedCandidates: [CleanupCandidate] { candidates.filter { selectedCandidateIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedCandidates.reduce(0) { $0 + $1.allocatedBytes } }
    var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Sift"
    }
    var versionLabel: String {
        if Bundle.main.object(forInfoDictionaryKey: "SiftBuildChannel") as? String == "development" {
            let reference = Bundle.main.object(forInfoDictionaryKey: "SiftBuildReference") as? String ?? "unknown"
            return "Development build · \(reference)"
        }
        return "Version \(updateService.currentVersion) (\(updateService.buildNumber))"
    }
    var totalReclaimableBytes: Int64 {
        workspaces.reduce(0) { $0 + $1.reclaimableBytes }
            + dockerState.reclaimableBytes
            + globalCaches.reduce(0) { $0 + $1.reclaimableBytes }
    }
    var repositoryGroups: [RepositoryGroup] {
        Dictionary(grouping: workspaces, by: \.repositoryID)
            .map { repositoryID, workspaces in
                RepositoryGroup(
                    repositoryID: repositoryID,
                    name: workspaces.first?.repositoryName ?? "Repository",
                    workspaces: workspaces.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
                )
            }
            .sorted {
                if $0.reclaimableBytes == $1.reclaimableBytes { return $0.name < $1.name }
                return $0.reclaimableBytes > $1.reclaimableBytes
            }
    }

    func scan(inBackground: Bool = false, preservingMessage: Bool = false) {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        isBackgroundRefreshing = inBackground
        scannedWorkspaceCount = 0
        discoveredWorkspaceCount = 0
        reusedCandidateSizeCount = 0
        measuredCandidateSizeCount = 0
        if !preservingMessage { lastMessage = nil }
        let scanStartedAt = ContinuousClock.now
        let roots = searchRoots
        let scanner = scanner
        let docker = docker
        let globalCacheService = globalCacheService

        Task {
            if !inBackground { dockerState = .checking }

            async let refreshedDockerState: DockerState = Task.detached(priority: .utility) { docker.status() }.value
            async let refreshedGlobalCaches: [GlobalCache] = Task.detached(priority: .utility) { globalCacheService.inspectAll() }.value

            let knownRoots = roots.filter(scanner.usesShallowDiscovery)
            let generalRoots = roots.filter { !scanner.usesShallowDiscovery(for: $0) }
            let knownWorkspaceURLs = await Task.detached(priority: .userInitiated) {
                scanner.discoverWorkspaces(in: knownRoots)
            }.value
            discoveredWorkspaceCount = knownWorkspaceURLs.count

            let generalDiscovery = Task.detached(priority: .utility) {
                scanner.discoverWorkspaces(in: generalRoots)
            }

            let previousByPath = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.url.path, $0) })
            var refreshed = await scanBatch(
                knownWorkspaceURLs,
                scanner: scanner,
                existing: [],
                previousByPath: previousByPath,
                publishesProgressively: !inBackground
            )
            if !refreshed.isEmpty { scanCache.save(refreshed) }
            let knownPaths = Set(knownWorkspaceURLs.map(\.path))
            let generalWorkspaceURLs = await generalDiscovery.value.filter { !knownPaths.contains($0.path) }
            discoveredWorkspaceCount += generalWorkspaceURLs.count
            refreshed = await scanBatch(
                generalWorkspaceURLs,
                scanner: scanner,
                existing: refreshed,
                previousByPath: previousByPath,
                publishesProgressively: !inBackground
            )

            workspaces = refreshed
            selectedCandidateIDs.formIntersection(refreshed.flatMap(\.candidates).map(\.id))
            scanCache.save(refreshed)
            dockerState = await refreshedDockerState
            globalCaches = await refreshedGlobalCaches.sorted { $0.bytes > $1.bytes }
            let completedAt = Date()
            lastSyncedAt = completedAt
            UserDefaults.standard.set(completedAt, forKey: lastSyncedKey)
            let elapsed = scanStartedAt.duration(to: .now)
            lastScanDuration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            isScanning = false
            isBackgroundRefreshing = false
        }
    }

    func scanIfStale(now: Date = Date(), maximumAge: TimeInterval = 60) {
        guard !isScanning, !isCleaning else { return }
        guard !workspaces.isEmpty, let lastSyncedAt else {
            scan()
            return
        }
        if now.timeIntervalSince(lastSyncedAt) >= maximumAge {
            scan(inBackground: true)
        }
    }

    private func scanBatch(
        _ urls: [URL],
        scanner: WorkspaceScanner,
        existing: [Workspace],
        previousByPath: [String: Workspace],
        publishesProgressively: Bool
    ) async -> [Workspace] {
        var refreshed = existing
        await withTaskGroup(of: WorkspaceScanResult.self) { group in
            var iterator = urls.makeIterator()
            for _ in 0..<min(4, urls.count) {
                if let url = iterator.next() {
                    group.addTask { scanner.scanWorkspace(url, previous: previousByPath[url.path]) }
                }
            }

            while let result = await group.next() {
                let workspace = result.workspace
                scannedWorkspaceCount += 1
                reusedCandidateSizeCount += result.reusedSizeCount
                measuredCandidateSizeCount += result.measuredSizeCount
                if !workspace.candidates.isEmpty {
                    refreshed.append(workspace)
                    if publishesProgressively {
                        workspaces = refreshed.sorted {
                            if $0.reclaimableBytes == $1.reclaimableBytes { return $0.name < $1.name }
                            return $0.reclaimableBytes > $1.reclaimableBytes
                        }
                    }
                }
                if let url = iterator.next() {
                    group.addTask { scanner.scanWorkspace(url, previous: previousByPath[url.path]) }
                }
            }
        }
        return refreshed
    }

    func cleanSelected() {
        let selected = selectedCandidates
        guard !selected.isEmpty, !isCleaning else { return }
        isCleaning = true
        let cleaner = cleaner
        let currentWorkspaces = workspaces

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                cleaner.remove(selected, from: currentWorkspaces)
            }.value
            isCleaning = false
            lastTrashedURLs = result.trashedURLs
            let containsHiddenFolders = result.trashedURLs.contains { $0.lastPathComponent.hasPrefix(".") }
            if result.failed.isEmpty {
                let hiddenHint = containsHiddenFolders ? " Finder hides dot-folders; in Trash press ⇧⌘. to show them." : ""
                lastMessage = "Moved \(result.trashed.count) folder\(result.trashed.count == 1 ? "" : "s") to Trash · up to \(ByteFormatting.string(result.reclaimedBytes)) pending.\(hiddenHint)"
            } else {
                lastMessage = "Moved \(result.trashed.count) folders to Trash; \(result.failed.count) could not be moved."
            }
            scan(preservingMessage: true)
        }
    }

    func showLastTrashedItems() {
        guard !lastTrashedURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastTrashedURLs)
        if lastTrashedURLs.contains(where: { $0.lastPathComponent.hasPrefix(".") }) {
            lastMessage = "Finder hides dot-prefixed folders. In the Trash window, press ⇧⌘. to show them."
        }
    }

    func pruneDockerImages() {
        guard !isCleaning else { return }
        isCleaning = true
        let docker = docker
        let before = Self.diskSpaceSnapshot().available
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) { try docker.pruneUnusedData() }.value
                refreshDiskSpace()
                let hostFreed = max(0, (availableDiskBytes ?? before ?? 0) - (before ?? availableDiskBytes ?? 0))
                let dockerFreed = DockerService.reclaimedBytes(fromPruneOutput: output)
                let dockerReport = dockerFreed.map { "Docker reports \(ByteFormatting.string($0)) reclaimed" } ?? "Docker cleanup completed"
                lastMessage = hostFreed > 0
                    ? "\(dockerReport) · macOS free space increased by \(ByteFormatting.string(hostFreed))."
                    : "\(dockerReport); Docker's VM disk may release macOS space later."
            } catch {
                lastMessage = "Docker cleanup failed: \(error.localizedDescription)"
            }
            isCleaning = false
            scan(preservingMessage: true)
        }
    }

    func cleanGlobalCache(_ cache: GlobalCache) {
        guard !isCleaning else { return }
        isCleaning = true
        cleaningGlobalCacheID = cache.id
        lastMessage = "Cleaning \(cache.name)…"
        replaceGlobalCache(cache, state: .checking)
        let service = globalCacheService
        let before = Self.diskSpaceSnapshot().available
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try service.clean(id: cache.id) }.value
                let refreshed = await Task.detached(priority: .utility) { service.inspect(id: cache.id) }.value
                if let refreshed { replaceGlobalCache(refreshed) }
                let remainingBytes = refreshed?.bytes ?? 0
                let removedFromCache = max(0, cache.bytes - remainingBytes)
                try? await Task.sleep(for: .milliseconds(300))
                refreshDiskSpace()
                let actuallyFreed = max(0, (availableDiskBytes ?? before ?? 0) - (before ?? availableDiskBytes ?? 0))
                if removedFromCache > 0 {
                    let verb = cache.onlyPrunesUnusedData ? "pruned" : "cleaned"
                    lastMessage = actuallyFreed > 0
                        ? "\(cache.name) \(verb) · estimate dropped by \(ByteFormatting.string(removedFromCache)); macOS free space increased by \(ByteFormatting.string(actuallyFreed))."
                        : "\(cache.name) \(verb) · estimate dropped by \(ByteFormatting.string(removedFromCache)); macOS reported no immediate free-space change."
                } else {
                    lastMessage = "\(cache.name) cleanup completed; no additional cache data was removed."
                }
            } catch {
                lastMessage = "\(cache.name) cleanup failed: \(error.localizedDescription)"
                if let refreshed = await Task.detached(priority: .utility, operation: { service.inspect(id: cache.id) }).value {
                    replaceGlobalCache(refreshed)
                } else {
                    replaceGlobalCache(cache, state: .failed(error.localizedDescription))
                }
            }
            cleaningGlobalCacheID = nil
            isCleaning = false
        }
    }

    private func replaceGlobalCache(_ cache: GlobalCache) {
        guard let index = globalCaches.firstIndex(where: { $0.id == cache.id }) else { return }
        globalCaches[index] = cache
    }

    private func replaceGlobalCache(_ cache: GlobalCache, state: GlobalCache.State) {
        replaceGlobalCache(GlobalCache(
            id: cache.id,
            name: cache.name,
            detail: cache.detail,
            symbolName: cache.symbolName,
            state: state
        ))
    }

    func checkForUpdates() async {
        guard updateService.repository != nil else {
            updateState = .unavailable
            return
        }
        if case .downloading = updateState { return }
        updateState = .checking
        do {
            if let release = try await updateService.checkForUpdate() {
                updateState = .available(release)
            } else {
                updateState = .upToDate(Date())
            }
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    func installUpdate(_ release: UpdateRelease) {
        guard case .available = updateState else { return }
        updateState = .downloading(release)
        let service = updateService
        Task {
            do {
                let stagedApp = try await service.downloadAndStage(release)
                try service.launchInstaller(for: stagedApp)
            } catch {
                if (error as? UpdateError) == .installLocationNotWritable {
                    NSWorkspace.shared.open(release.releasePageURL)
                    updateState = .failed("Opened the release because this installation is not writable")
                } else {
                    updateState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func openRelease(_ release: UpdateRelease) {
        NSWorkspace.shared.open(release.releasePageURL)
    }

    func addSearchRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder containing your projects"
        panel.prompt = "Add Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        for url in panel.urls.map(\.standardizedFileURL) where !searchRoots.contains(url) {
            searchRoots.append(url)
        }
        saveRoots()
        scan()
    }

    func removeSearchRoot(_ url: URL) {
        searchRoots.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        saveRoots()
        scan()
    }

    func toggleWorkspace(_ workspace: Workspace, selected: Bool) {
        for candidate in workspace.candidates {
            if selected { selectedCandidateIDs.insert(candidate.id) }
            else { selectedCandidateIDs.remove(candidate.id) }
        }
    }

    func selectedCount(in workspace: Workspace) -> Int {
        workspace.candidates.count { selectedCandidateIDs.contains($0.id) }
    }

    func toggleWorkspaceSelection(_ workspace: Workspace) {
        toggleWorkspace(workspace, selected: selectedCount(in: workspace) != workspace.candidates.count)
    }

    func selectAll() {
        selectedCandidateIDs = Set(candidates.map(\.id))
    }

    func deselectAll() {
        selectedCandidateIDs.removeAll()
    }

    func freeDiskSpace() -> Int64? {
        availableDiskBytes
    }

    func diskCapacity() -> Int64? {
        totalDiskBytes
    }

    func refreshDiskSpace() {
        let values = Self.diskSpaceSnapshot()
        availableDiskBytes = values.available
        totalDiskBytes = values.total
    }

    private static func diskSpaceSnapshot() -> (available: Int64?, total: Int64?) {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        )
        return (
            values?.volumeAvailableCapacity.map(Int64.init),
            values?.volumeTotalCapacity.map(Int64.init)
        )
    }

    private func saveRoots() {
        UserDefaults.standard.set(searchRoots.map(\.path), forKey: defaultsKey)
    }

    private static func migrateLegacyDefaultsIfNeeded() {
        let current = UserDefaults.standard
        let marker = "siftMigratedLegacyDefaults"
        guard current.object(forKey: marker) == nil else { return }
        let legacySuites = ["com.dominikhait.sift", "com.dominikhait.devsweep"]
            .compactMap(UserDefaults.init(suiteName:))
        for legacy in legacySuites {
            if current.object(forKey: "searchRoots") == nil,
               let roots = legacy.stringArray(forKey: "searchRoots") {
                current.set(roots, forKey: "searchRoots")
            }
            if current.object(forKey: "lastSuccessfulScanDate") == nil,
               let date = legacy.object(forKey: "lastSuccessfulScanDate") as? Date {
                current.set(date, forKey: "lastSuccessfulScanDate")
            }
        }
        current.set(true, forKey: marker)
    }

    private static func defaultSearchRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let candidates = [
            home.appendingPathComponent(".codex/worktrees", isDirectory: true),
            home.appendingPathComponent("claude/worktrees", isDirectory: true),
            home.appendingPathComponent(".claude/worktrees", isDirectory: true),
            home.appendingPathComponent(".cursor/worktrees", isDirectory: true),
            home.appendingPathComponent(".t3/worktrees", isDirectory: true),
            home.appendingPathComponent(".superset/worktrees", isDirectory: true),
            home.appendingPathComponent(".superconductor/worktrees", isDirectory: true),
            home.appendingPathComponent(".copilot/workspaces", isDirectory: true),
            home.appendingPathComponent(".21st/worktrees", isDirectory: true),
            home.appendingPathComponent("conductor/workspaces", isDirectory: true),
            home.appendingPathComponent("Developer", isDirectory: true),
            home.appendingPathComponent("Projects", isDirectory: true),
            home.appendingPathComponent("Documents/Eigene_Projekte", isDirectory: true)
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
