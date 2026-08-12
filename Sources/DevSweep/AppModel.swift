import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var dockerState: DockerState = .checking
    @Published var selectedCandidateIDs = Set<String>()
    @Published var isScanning = false
    @Published var scannedWorkspaceCount = 0
    @Published var discoveredWorkspaceCount = 0
    @Published var reusedCandidateSizeCount = 0
    @Published var measuredCandidateSizeCount = 0
    @Published var lastScanDuration: TimeInterval?
    @Published var isCleaning = false
    @Published var lastMessage: String?
    @Published var lastSyncedAt: Date?
    @Published var searchRoots: [URL]

    private let scanner = WorkspaceScanner()
    private let cleaner = CleanupService()
    private let docker = DockerService()
    private let scanCache = ScanCache()
    private let defaultsKey = "searchRoots"
    private let lastSyncedKey = "lastSuccessfulScanDate"

    init() {
        let defaults = Self.defaultSearchRoots()
        if let stored = UserDefaults.standard.stringArray(forKey: defaultsKey), !stored.isEmpty {
            let combined = stored.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL } + defaults
            searchRoots = Array(Dictionary(grouping: combined, by: \.path).compactMap(\.value.first))
        } else {
            searchRoots = defaults
        }
        workspaces = scanCache.load(under: searchRoots)
        selectedCandidateIDs = Set(workspaces.flatMap(\.candidates).map(\.id))
        lastSyncedAt = UserDefaults.standard.object(forKey: lastSyncedKey) as? Date
    }

    var candidates: [CleanupCandidate] { workspaces.flatMap(\.candidates) }
    var selectedCandidates: [CleanupCandidate] { candidates.filter { selectedCandidateIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedCandidates.reduce(0) { $0 + $1.allocatedBytes } }
    var totalReclaimableBytes: Int64 { workspaces.reduce(0) { $0 + $1.reclaimableBytes } + dockerState.reclaimableBytes }
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

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scannedWorkspaceCount = 0
        discoveredWorkspaceCount = 0
        reusedCandidateSizeCount = 0
        measuredCandidateSizeCount = 0
        lastMessage = nil
        let scanStartedAt = ContinuousClock.now
        let roots = searchRoots
        let scanner = scanner
        let docker = docker

        Task {
            dockerState = .checking

            Task {
                let newDockerState = await Task.detached(priority: .utility) { docker.status() }.value
                dockerState = newDockerState
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
            var refreshed = await scanBatch(knownWorkspaceURLs, scanner: scanner, existing: [], previousByPath: previousByPath)
            if !refreshed.isEmpty { scanCache.save(refreshed) }
            let knownPaths = Set(knownWorkspaceURLs.map(\.path))
            let generalWorkspaceURLs = await generalDiscovery.value.filter { !knownPaths.contains($0.path) }
            discoveredWorkspaceCount += generalWorkspaceURLs.count
            refreshed = await scanBatch(generalWorkspaceURLs, scanner: scanner, existing: refreshed, previousByPath: previousByPath)

            workspaces = refreshed
            selectedCandidateIDs = Set(refreshed.flatMap(\.candidates).map(\.id))
            scanCache.save(refreshed)
            let completedAt = Date()
            lastSyncedAt = completedAt
            UserDefaults.standard.set(completedAt, forKey: lastSyncedKey)
            let elapsed = scanStartedAt.duration(to: .now)
            lastScanDuration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            isScanning = false
        }
    }

    private func scanBatch(
        _ urls: [URL],
        scanner: WorkspaceScanner,
        existing: [Workspace],
        previousByPath: [String: Workspace]
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
                    workspaces = refreshed.sorted {
                        if $0.reclaimableBytes == $1.reclaimableBytes { return $0.name < $1.name }
                        return $0.reclaimableBytes > $1.reclaimableBytes
                    }
                    selectedCandidateIDs = Set(workspaces.flatMap(\.candidates).map(\.id))
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
            if result.failed.isEmpty {
                lastMessage = "Moved \(result.trashed.count) folder\(result.trashed.count == 1 ? "" : "s") · \(ByteFormatting.string(result.reclaimedBytes)) to Trash."
            } else {
                lastMessage = "Moved \(result.trashed.count) folders to Trash; \(result.failed.count) could not be moved."
            }
            scan()
        }
    }

    func pruneDockerImages() {
        guard !isCleaning else { return }
        isCleaning = true
        let docker = docker
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try docker.pruneUnusedImages() }.value
                lastMessage = "Unused Docker images were removed. Containers and volumes were preserved."
            } catch {
                lastMessage = "Docker cleanup failed: \(error.localizedDescription)"
            }
            isCleaning = false
            scan()
        }
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
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func diskCapacity() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity.map(Int64.init)
    }

    private func saveRoots() {
        UserDefaults.standard.set(searchRoots.map(\.path), forKey: defaultsKey)
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
