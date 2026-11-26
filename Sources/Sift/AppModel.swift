import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let storageOverview = StorageOverviewModel()
    let memoryOverview = MemoryOverviewModel()
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
    @Published private(set) var cleanupActivity = CleanupActivity()
    @Published private(set) var cleanupErrors: [String: String] = [:]
    var isCleaning: Bool { !cleanupActivity.isEmpty }
    var isCleaningDocker: Bool { cleanupActivity.jobs["docker"] != nil }
    var isCleaningWorktrees: Bool { cleanupActivity.jobs["worktrees"] != nil }
    var cleaningGlobalCacheIDs: Set<String> {
        Set(cleanupActivity.jobs.keys.filter { $0.hasPrefix("cache:") }.map { String($0.dropFirst(6)) })
    }
    @Published var lastMessage: String?
    @Published private(set) var lastCleanupObservation: CleanupObservation?
    @Published var lastSyncedAt: Date?
    @Published var searchRoots: [URL]
    @Published var updateState: UpdateState = .idle {
        didSet { updateStateChanged() }
    }
    @Published private(set) var latestUpdateRelease: UpdateRelease?
    @Published private(set) var presentedUpdateRelease: UpdateRelease?
    var isUpdating: Bool { if case .downloading = updateState { return true }; return false }
    var hasAvailableUpdate: Bool { latestUpdateRelease != nil && !isUpdating }
    var installedVersion: String { updateService.currentVersion }
    @Published var automaticallyInstallsUpdates: Bool {
        didSet {
            updatePreferences.set(automaticallyInstallsUpdates, forKey: "automaticallyInstallsUpdates.v1")
            automaticInstallIdleSince = nil
            if automaticallyInstallsUpdates {
                beginAutomaticUpdateIfEligible()
                scheduleAutomaticInstallation()
            } else {
                automaticInstallTask?.cancel()
                automaticInstallTask = nil
            }
        }
    }
    var isPreparingUpdate: Bool { if case .preparing = updateState { return true }; return false }
    var isUpdateReady: Bool { if case .ready = updateState { return true }; return false }
    var updateReadyTitle: String { isUpdateReady ? "Restart to Update" : "Update & Relaunch" }
    @Published private(set) var availableDiskBytes: Int64?
    @Published private(set) var totalDiskBytes: Int64?
    @Published private(set) var diskHistory = DiskSpaceHistory(samples: (UserDefaults.standard.data(forKey: "diskSpaceHistory.v1")
        .flatMap { try? JSONDecoder().decode([DiskSpaceSample].self, from: $0) }) ?? [])
    @Published private(set) var lastTrashedURLs: [URL] = []
    @Published var deletesImmediately: Bool {
        didSet { UserDefaults.standard.set(deletesImmediately, forKey: "deleteGeneratedFoldersImmediately") }
    }

    private let scanner = WorkspaceScanner()
    private let cleaner = CleanupService()
    private let docker = DockerService()
    private let globalCacheService = GlobalCacheService()
    private let uvLockProcessService = UVLockProcessService()
    private let scanCache = ScanCache()
    private let updateService = UpdateService()
    private let defaultsKey = "searchRoots"
    private let lastSyncedKey = "lastSuccessfulScanDate"
    private var rescanWhenIdle = false
    private var globalCacheRevision = 0
    private let cleanup: CleanupExecution
    private let updates: UpdateExecution
    private let updatesConfigured: Bool
    private let updatePreferences: UserDefaults
    private let showsUpdateWindows: Bool
    private let updatePolicyKey = "updatePromptPolicy.v1"
    private var updatePromptPolicy: UpdatePromptPolicy
    private var updatePromptWindow: UpdatePromptWindow?
    private var updateInteractionActive = false
    private var updatePromptsAllowed = true
    private var checkingUpdates = false
    private var presentedPromptWasManual = false
    private var pendingManualUpdatePrompt = false
    private var stagedUpdate: (release: UpdateRelease, app: URL)?
    private var automaticInstallTask: Task<Void, Never>?
    private var automaticInstallIdleSince: Date?
    private let startsAutomaticInstallationTimer: Bool
    private let updateWindowsAreOpen: @MainActor () -> Bool

    init(cleanup: CleanupExecution = .live, updates: UpdateExecution? = nil,
         updatePreferences: UserDefaults = .standard, showsUpdateWindows: Bool = true,
         startsAutomaticUpdateChecks: Bool = true, startsAutomaticInstallationTimer: Bool = true,
         updateWindowsAreOpen: @escaping @MainActor () -> Bool = {
             NSApp.windows.contains { $0.isVisible && ($0.canBecomeKey || $0.attachedSheet != nil) }
         }) {
        self.cleanup = cleanup
        self.updates = updates ?? .live(service: UpdateService())
        self.updatesConfigured = updates != nil || UpdateService().repository != nil
        self.updatePreferences = updatePreferences
        self.showsUpdateWindows = showsUpdateWindows
        self.startsAutomaticInstallationTimer = startsAutomaticInstallationTimer
        self.updateWindowsAreOpen = updateWindowsAreOpen
        self.automaticallyInstallsUpdates = updatePreferences.bool(forKey: "automaticallyInstallsUpdates.v1")
        self.updatePromptPolicy = updatePreferences.data(forKey: "updatePromptPolicy.v1")
            .flatMap { try? JSONDecoder().decode(UpdatePromptPolicy.self, from: $0) } ?? UpdatePromptPolicy()
        deletesImmediately = UserDefaults.standard.bool(forKey: "deleteGeneratedFoldersImmediately")
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
        if !updatesConfigured {
            updateState = .unavailable
        } else if startsAutomaticUpdateChecks {
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
    var selectedConservativeBytes: Int64 { selectedCandidates.reduce(0) { $0 + $1.conservativeBytes } }
    var cleanableGlobalCaches: [GlobalCache] {
        globalCaches.filter { cache in
            guard !isUpdating, cache.includedInCleanAll, !cache.skippedByBulkCleanup(), canCleanCache(cache) else { return false }
            if case let .available(bytes, _) = cache.state { return bytes > 0 }
            return false
        }
    }
    var cleanableGlobalStorageCount: Int {
        cleanableGlobalCaches.count + (dockerState.reclaimableBytes > 0 && !isCleaningDocker && !isUpdating ? 1 : 0)
    }
    func canCleanCache(_ cache: GlobalCache) -> Bool {
        !isUpdating && cleanupActivity.canStart("cache:" + cache.id, paths: cache.state.path.map { [$0] } ?? [])
    }
    var canCleanSelected: Bool {
        !isUpdating && !selectedCandidates.isEmpty && cleanupActivity.canStart("worktrees", paths: selectedCandidates.map { $0.url.path })
    }
    @discardableResult private func beginCleanup(_ id: String, paths: [String] = []) -> Bool {
        guard !isUpdating, cleanupActivity.begin(id, paths: paths) else { return false }
        automaticInstallIdleSince = nil
        if let release = presentedUpdateRelease {
            pendingManualUpdatePrompt = presentedPromptWasManual
            updatePromptPolicy.deferredForCleanup(release.version)
            saveUpdatePromptPolicy()
            closeUpdatePromptQuietly()
        }
        cleanupErrors[id] = nil
        globalCacheRevision += 1
        if isScanning { rescanWhenIdle = true }
        return true
    }
    private func finishCleanup(_ id: String, needsRescan: Bool = false) {
        if cleanupActivity.jobs[id]?.overlapped == true, let message = lastMessage {
            lastMessage = message + " Free-space changes include concurrent cleanups and other app activity."
        }
        cleanupActivity.finish(id)
        beginAutomaticUpdateIfEligible()
        maybePresentUpdatePrompt()
        if needsRescan { rescanWhenIdle = true }
        if rescanWhenIdle, !isCleaning, !isScanning {
            rescanWhenIdle = false
            scan(inBackground: true, preservingMessage: true)
        }
    }
    var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Sift"
    }
    func selectOlderGeneratedFolders(days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        selectedCandidateIDs = Set(candidates.filter { ($0.modificationDate ?? .distantFuture) < cutoff }.map(\.id))
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
    var conservativeWorktreeBytes: Int64 {
        workspaces.reduce(0) { $0 + $1.conservativeReclaimableBytes }
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
        let cacheRevision = globalCacheRevision

        Task {
            if !inBackground { dockerState = .checking }

            async let refreshedDockerState: DockerState = Task.detached(priority: .utility) { docker.status() }.value
            let globalRefresh = Task {
                let refreshed = await Task.detached(priority: .utility) {
                    globalCacheService.inspectAll { cache in
                        Task { @MainActor [weak self] in
                            guard let self, self.globalCacheRevision == cacheRevision, !self.isCleaning else { return }
                            self.replaceGlobalCache(cache)
                        }
                    }
                }.value
                if globalCacheRevision == cacheRevision, !isCleaning { globalCaches = refreshed.sorted { $0.bytes > $1.bytes } }
            }

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
                publishesProgressively: !inBackground,
                revision: cacheRevision
            )
            if !refreshed.isEmpty, globalCacheRevision == cacheRevision { scanCache.save(refreshed) }
            let knownPaths = Set(knownWorkspaceURLs.map(\.path))
            let generalWorkspaceURLs = await generalDiscovery.value.filter { !knownPaths.contains($0.path) }
            discoveredWorkspaceCount += generalWorkspaceURLs.count
            refreshed = await scanBatch(
                generalWorkspaceURLs,
                scanner: scanner,
                existing: refreshed,
                previousByPath: previousByPath,
                publishesProgressively: !inBackground,
                revision: cacheRevision
            )

            if globalCacheRevision == cacheRevision {
                workspaces = refreshed
                selectedCandidateIDs.formIntersection(refreshed.flatMap(\.candidates).map(\.id))
                scanCache.save(refreshed)
            }
            let refreshedDocker = await refreshedDockerState
            if globalCacheRevision == cacheRevision { dockerState = refreshedDocker }
            await globalRefresh.value
            let completedAt = Date()
            if globalCacheRevision == cacheRevision {
                lastSyncedAt = completedAt
                UserDefaults.standard.set(completedAt, forKey: lastSyncedKey)
            }
            let elapsed = scanStartedAt.duration(to: .now)
            lastScanDuration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            isScanning = false
            isBackgroundRefreshing = false
            if rescanWhenIdle, !isCleaning {
                rescanWhenIdle = false
                scan(inBackground: true, preservingMessage: true)
            }
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
        publishesProgressively: Bool,
        revision: Int
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
                    if publishesProgressively, globalCacheRevision == revision, !isCleaning {
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
        guard !selected.isEmpty, beginCleanup("worktrees", paths: selected.map { $0.url.path }) else { return }
        let cleaner = cleaner
        let currentWorkspaces = workspaces
        let mode: CleanupMode = deletesImmediately ? .deleteImmediately : .trash
        let before = Self.diskSpaceSnapshot().available

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                cleaner.remove(selected, from: currentWorkspaces, mode: mode)
            }.value
            lastTrashedURLs = result.trashedURLs
            let containsHiddenFolders = result.trashedURLs.contains { $0.lastPathComponent.hasPrefix(".") }
            if mode == .deleteImmediately, result.failed.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
                refreshDiskSpace(cleanupEvent: true)
                let after = availableDiskBytes ?? Self.diskSpaceSnapshot().available
                let actuallyFreed = max(0, (after ?? before ?? 0) - (before ?? after ?? 0))
                lastMessage = "Permanently deleted \(result.trashed.count) generated folder\(result.trashed.count == 1 ? "" : "s") · macOS free space increased by \(ByteFormatting.string(actuallyFreed))."
            } else if mode == .deleteImmediately {
                try? await Task.sleep(for: .milliseconds(500))
                refreshDiskSpace(cleanupEvent: true)
                let after = availableDiskBytes ?? Self.diskSpaceSnapshot().available
                let actuallyFreed = max(0, (after ?? before ?? 0) - (before ?? after ?? 0))
                lastMessage = "Permanently deleted \(result.trashed.count) generated folders; \(result.failed.count) failed · macOS free space increased by \(ByteFormatting.string(actuallyFreed))."
            } else if result.failed.isEmpty {
                let hiddenHint = containsHiddenFolders ? " Finder hides dot-folders; in Trash press ⇧⌘. to show them." : ""
                lastMessage = "Moved \(result.trashed.count) folder\(result.trashed.count == 1 ? "" : "s") to Trash · no space is released until Trash is emptied.\(hiddenHint)"
            } else {
                lastMessage = "Moved \(result.trashed.count) folders to Trash; \(result.failed.count) could not be moved."
            }
            recordCleanupObservation("Worktree folders", before: before, movedToTrash: mode == .trash && !result.trashedURLs.isEmpty)
            selectedCandidateIDs.subtract(result.trashed.map(\.id))
            let removed = Set(result.trashed.map(\.id))
            workspaces = workspaces.map { workspace in
                Workspace(url: workspace.url, name: workspace.name, branch: workspace.branch,
                          repositoryID: workspace.repositoryID, repositoryName: workspace.repositoryName,
                          candidates: workspace.candidates.filter { !removed.contains($0.id) })
            }
            scanCache.save(workspaces)
            finishCleanup("worktrees", needsRescan: true)
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
        guard beginCleanup("docker") else { return }
        let cleanup = cleanup
        let before = Self.diskSpaceSnapshot().available
        Task {
            let message: String
            do {
                let output = try await Task.detached(priority: .userInitiated) { try await cleanup.pruneDocker() }.value
                refreshDiskSpace(cleanupEvent: true)
                let hostFreed = max(0, (availableDiskBytes ?? before ?? 0) - (before ?? availableDiskBytes ?? 0))
                let dockerFreed = DockerService.reclaimedBytes(fromPruneOutput: output)
                recordCleanupObservation("Docker", before: before)
                let dockerReport = dockerFreed.map { "Docker reports \(ByteFormatting.string($0)) reclaimed" } ?? "Docker cleanup completed"
                message = hostFreed > 0
                    ? "\(dockerReport) · macOS free space increased by \(ByteFormatting.string(hostFreed))."
                    : "\(dockerReport); Docker's VM disk may release macOS space later."
            } catch {
                message = "Docker cleanup failed: \(error.localizedDescription)"
                cleanupErrors["docker"] = error.localizedDescription
            }
            dockerState = await Task.detached(priority: .utility) { await cleanup.inspectDocker() }.value
            lastMessage = message
            finishCleanup("docker")
        }
    }

    func cleanGlobalCache(_ cache: GlobalCache) {
        guard let cache = globalCaches.first(where: { $0.id == cache.id }),
              case .available = cache.state,
              beginCleanup("cache:" + cache.id, paths: cache.state.path.map { [$0] } ?? []) else { return }
        lastMessage = "Cleaning \(cache.name)…"
        replaceGlobalCache(cache, state: .checking)
        let cleanup = cleanup
        let before = Self.diskSpaceSnapshot().available
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try await cleanup.cleanCache(cache.id) }.value
                let refreshed = await Task.detached(priority: .utility) { await cleanup.inspectCache(cache.id) }.value
                if let refreshed { replaceGlobalCache(refreshed) }
                else { replaceGlobalCache(cache, state: .failed("Cleanup finished, but the cache could not be remeasured")) }
                let remainingBytes = refreshed?.measuredBytes
                let removedFromCache = remainingBytes.map { max(0, cache.bytes - $0) }
                try? await Task.sleep(for: .milliseconds(300))
                refreshDiskSpace(cleanupEvent: true)
                let actuallyFreed = max(0, (availableDiskBytes ?? before ?? 0) - (before ?? availableDiskBytes ?? 0))
                if let removedFromCache, removedFromCache > 0 {
                    let verb = cache.onlyPrunesUnusedData ? "pruned" : "cleaned"
                    lastMessage = actuallyFreed > 0
                        ? "\(cache.name) \(verb) · stored size decreased by \(ByteFormatting.string(removedFromCache)); macOS free space increased by \(ByteFormatting.string(actuallyFreed))."
                        : "\(cache.name) \(verb) · stored size decreased by \(ByteFormatting.string(removedFromCache)); macOS reported no immediate free-space change."
                } else if remainingBytes == nil {
                    lastMessage = "\(cache.name) cleanup command finished; remaining size could not be measured. See the observed free-space result."
                } else {
                    lastMessage = actuallyFreed > 0
                        ? "\(cache.name) cleanup completed; macOS free space increased by \(ByteFormatting.string(actuallyFreed))."
                        : "\(cache.name) cleanup completed; stored size did not decrease and macOS reported no immediate free-space increase. Shared data or freshly generated cache files can explain this."
                }
                recordCleanupObservation(cache.name, before: before)
            } catch {
                cleanupErrors["cache:" + cache.id] = error.localizedDescription
                if let refreshed = await Task.detached(priority: .utility, operation: { await cleanup.inspectCache(cache.id) }).value {
                    replaceGlobalCache(refreshed)
                } else {
                    replaceGlobalCache(cache, state: .failed(error.localizedDescription))
                }
                lastMessage = "\(cache.name) cleanup failed: \(error.localizedDescription)"
            }
            finishCleanup("cache:" + cache.id)
        }
    }

    func stopUVLockProcesses() {
        let uvCache = globalCaches.first(where: { $0.id == "uv" })
        guard let uvCache, case .blocked = uvCache.state else { return }
        guard beginCleanup("cache:uv", paths: uvCache.state.path.map { [$0] } ?? []) else { return }
        lastMessage = "Stopping uv processes…"
        let processService = uvLockProcessService
        let cacheService = globalCacheService
        let uvPath: String?
        if let cache = globalCaches.first(where: { $0.id == "uv" }), case let .blocked(_, path, _) = cache.state { uvPath = path }
        else { uvPath = nil }
        Task {
            let message: String
            do {
                let count = try await Task.detached(priority: .userInitiated) {
                    try processService.stopHolders(cachePath: uvPath)
                }.value
                message = count == 0
                    ? "No uv processes are holding the cache lock."
                    : "Stopped \(count) uv process\(count == 1 ? "" : "es"). Their development servers and commands were terminated."
            } catch {
                message = "Could not stop uv processes: \(error.localizedDescription)"
                cleanupErrors["cache:uv"] = error.localizedDescription
            }
            if let refreshed = await Task.detached(priority: .utility, operation: { cacheService.inspect(id: "uv") }).value {
                replaceGlobalCache(refreshed)
            }
            lastMessage = message
            finishCleanup("cache:uv")
        }
    }

    func cleanAllGlobalCaches() {
        // Each source reserves its own paths synchronously before launching.
        // This uses the same revalidation/confirmation scope as individual jobs.
        let caches = cleanableGlobalCaches
        let cleansDocker = dockerState.reclaimableBytes > 0 && !isCleaningDocker
        for cache in caches { cleanGlobalCache(cache) }
        if cleansDocker { pruneDockerImages() }
    }

    private func recordCleanupObservation(_ operation: String, before: Int64?, movedToTrash: Bool = false) {
        NativeScanCache.shared.invalidate()
        lastCleanupObservation = CleanupObservation(operation: operation, before: before,
                                                     after: Self.diskSpaceSnapshot().available,
                                                     movedToTrash: movedToTrash)
    }

    private func replaceGlobalCache(_ cache: GlobalCache) {
        guard let index = globalCaches.firstIndex(where: { $0.id == cache.id }) else { globalCaches.append(cache); return }
        globalCaches[index] = cache
    }

    private func replaceGlobalCache(_ cache: GlobalCache, state: GlobalCache.State) {
        replaceGlobalCache(GlobalCache(
            id: cache.id,
            name: cache.name,
            detail: cache.detail,
            symbolName: cache.symbolName,
            state: state,
            lastChanged: state == .checking ? cache.lastChanged : nil,
            skippedLocations: cache.skippedLocations
        ))
    }

    func checkForUpdates() async {
        guard updatesConfigured else {
            updateState = .unavailable
            return
        }
        guard !isUpdating, !isPreparingUpdate, !isUpdateReady, !checkingUpdates else { return }
        checkingUpdates = true
        defer { checkingUpdates = false }
        // Retain the existing badge while a periodic background check runs.
        if latestUpdateRelease == nil { updateState = .checking }
        do {
            let release = try await updates.check()
            guard !isUpdating, !isPreparingUpdate, !isUpdateReady else { return }
            if let release {
                updateState = .available(release)
            } else {
                updateState = .upToDate(Date())
            }
        } catch {
            guard !isUpdating, !isPreparingUpdate, !isUpdateReady else { return }
            updateState = .failed(error.localizedDescription)
        }
    }

    func installUpdate(_ release: UpdateRelease) {
        guard canInstallUpdate(release) else { return }
        if let stagedUpdate, stagedUpdate.release == release {
            installStagedUpdate(stagedUpdate.app, release: release, automatic: false)
            return
        }
        updateState = .downloading(release)
        Task {
            do {
                let stagedApp = try await updates.download(release)
                guard !isCleaning, updateState == .downloading(release) else {
                    updateState = .available(release)
                    return
                }
                try updates.install(stagedApp)
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

    func canInstallUpdate(_ release: UpdateRelease) -> Bool {
        guard !isCleaning, !isUpdating, latestUpdateRelease == release else { return false }
        switch updateState { case .available, .ready, .failed: return true; default: return false }
    }

    private func beginAutomaticUpdateIfEligible() {
        guard updatesConfigured, automaticallyInstallsUpdates, !isCleaning,
              case let .available(release) = updateState,
              updatePromptPolicy.allowsAutomaticUpdate(version: release.version, now: Date()) else { return }
        // Background preparation is read-only and must not block cleanup.
        updateState = .preparing(release)
        Task { [weak self, updates] in
            do {
                let app = try await updates.download(release)
                guard let self else { return }
                self.stagedUpdate = (release, app)
                self.updateState = .ready(release)
            } catch {
                self?.updateState = .failed("Could not prepare the automatic update: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleAutomaticInstallation() {
        guard automaticallyInstallsUpdates, isUpdateReady, startsAutomaticInstallationTimer, automaticInstallTask == nil else { return }
        automaticInstallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.automaticallyInstallsUpdates, self.isUpdateReady else { return }
                self.considerAutomaticUpdateInstallation()
            }
        }
    }

    /// Recheck every safety condition at the point of installation. A fresh
    /// continuous idle minute is required after any interaction or cleanup.
    func considerAutomaticUpdateInstallation(now: Date = Date()) {
        guard automaticallyInstallsUpdates, let stagedUpdate,
              updateState == .ready(stagedUpdate.release),
              updatePromptPolicy.allowsAutomaticUpdate(version: stagedUpdate.release.version, now: now),
              !isCleaning, !updateInteractionActive, presentedUpdateRelease == nil, !updateWindowsAreOpen() else {
            automaticInstallIdleSince = nil
            return
        }
        guard let since = automaticInstallIdleSince else { automaticInstallIdleSince = now; return }
        guard now.timeIntervalSince(since) >= 60 else { return }
        installStagedUpdate(stagedUpdate.app, release: stagedUpdate.release, automatic: true)
    }

    private func installStagedUpdate(_ app: URL, release: UpdateRelease, automatic: Bool) {
        guard canInstallUpdate(release) else { return }
        updateState = .downloading(release) // Reserve installation before launching the helper.
        do { try updates.install(app) }
        catch {
            if let failure = error as? UpdateError, failure == .invalidApplication || failure == .invalidSignature {
                stagedUpdate = nil // Retry must download a fresh bundle if staging was removed or changed.
            }
            // Never open a browser or steal focus after an automatic failure.
            if !automatic, (error as? UpdateError) == .installLocationNotWritable { NSWorkspace.shared.open(release.releasePageURL) }
            updateState = .failed("Could not install the update: \(error.localizedDescription). Retry from Settings.")
        }
    }

    func setUpdatePromptContext(active: Bool, allowsPrompt: Bool) {
        updateInteractionActive = active
        updatePromptsAllowed = allowsPrompt
        if active { automaticInstallIdleSince = nil }
        maybePresentUpdatePrompt()
    }

    func requestUpdatePrompt() {
        // This method is an explicit user action, including in a nonactivating
        // menu-bar panel whose focus notification has not arrived yet.
        updateInteractionActive = true
        pendingManualUpdatePrompt = true
        maybePresentUpdatePrompt()
        if !isCleaning, updateInteractionActive { updatePromptWindow?.present() }
    }

    func remindUpdateTomorrow(_ release: UpdateRelease, now: Date = Date()) {
        automaticInstallIdleSince = nil
        updatePromptPolicy.remindTomorrow(release.version, now: now)
        saveUpdatePromptPolicy()
        closeUpdatePromptQuietly()
    }

    func skipUpdateVersion(_ release: UpdateRelease) {
        automaticInstallIdleSince = nil
        updatePromptPolicy.skip(release.version)
        saveUpdatePromptPolicy()
        closeUpdatePromptQuietly()
    }

    private func saveUpdatePromptPolicy() {
        if let data = try? JSONEncoder().encode(updatePromptPolicy) { updatePreferences.set(data, forKey: updatePolicyKey) }
    }

    private func updateStateChanged() {
        if !isUpdateReady {
            automaticInstallTask?.cancel()
            automaticInstallTask = nil
            automaticInstallIdleSince = nil
        }
        switch updateState {
        case let .available(release):
            latestUpdateRelease = release
            if let current = presentedUpdateRelease, current != release { closeUpdatePromptQuietly() }
        case .upToDate, .unavailable:
            latestUpdateRelease = nil
            closeUpdatePromptQuietly()
        default: break
        }
        beginAutomaticUpdateIfEligible()
        scheduleAutomaticInstallation()
        maybePresentUpdatePrompt()
    }

    private func maybePresentUpdatePrompt(now: Date = Date()) {
        guard updateInteractionActive, !isCleaning, !isUpdating, presentedUpdateRelease == nil,
              !isPreparingUpdate, let release = latestUpdateRelease,
              pendingManualUpdatePrompt || (updatePromptsAllowed && (!automaticallyInstallsUpdates || isUpdateFailure)
                  && updatePromptPolicy.shouldPresent(version: release.version, now: now)) else { return }
        presentedPromptWasManual = pendingManualUpdatePrompt
        pendingManualUpdatePrompt = false
        updatePromptPolicy.presented(release.version)
        saveUpdatePromptPolicy()
        presentedUpdateRelease = release
        guard showsUpdateWindows else { return } // Deterministic, window-free tests.
        let controller = UpdatePromptWindow(model: self, release: release) { [weak self] userInitiated in
            guard let self, self.presentedUpdateRelease == release else { return }
            if userInitiated, !self.isUpdating, !self.automaticallyInstallsUpdates {
                self.updatePromptPolicy.remindTomorrow(release.version, now: Date())
                self.saveUpdatePromptPolicy()
            }
            self.presentedUpdateRelease = nil
            self.updatePromptWindow = nil
        }
        updatePromptWindow = controller
        controller.present()
    }

    private func closeUpdatePromptQuietly() {
        let controller = updatePromptWindow
        updatePromptWindow = nil
        presentedUpdateRelease = nil
        controller?.closeQuietly()
    }

    private var isUpdateFailure: Bool { if case .failed = updateState { return true }; return false }
    func dismissUpdatePrompt() { closeUpdatePromptQuietly() }

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

    func refreshDiskSpace(cleanupEvent: Bool = false) {
        let values = Self.diskSpaceSnapshot()
        availableDiskBytes = values.available
        totalDiskBytes = values.total
        if let free = values.available, let capacity = values.total,
           diskHistory.record(free: free, capacity: capacity, cleanup: cleanupEvent),
           let data = try? JSONEncoder().encode(diskHistory.samples) {
            UserDefaults.standard.set(data, forKey: "diskSpaceHistory.v1")
        }
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
