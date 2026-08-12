import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var dockerState: DockerState = .checking
    @Published var selectedCandidateIDs = Set<String>()
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var lastMessage: String?
    @Published var searchRoots: [URL]

    private let scanner = WorkspaceScanner()
    private let cleaner = CleanupService()
    private let docker = DockerService()
    private let defaultsKey = "searchRoots"

    init() {
        if let stored = UserDefaults.standard.stringArray(forKey: defaultsKey), !stored.isEmpty {
            searchRoots = stored.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            searchRoots = Self.defaultSearchRoots()
        }
    }

    var candidates: [CleanupCandidate] { workspaces.flatMap(\.candidates) }
    var selectedCandidates: [CleanupCandidate] { candidates.filter { selectedCandidateIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedCandidates.reduce(0) { $0 + $1.allocatedBytes } }
    var totalReclaimableBytes: Int64 { workspaces.reduce(0) { $0 + $1.reclaimableBytes } + dockerState.reclaimableBytes }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        lastMessage = nil
        let roots = searchRoots
        let scanner = scanner
        let docker = docker

        Task {
            async let workspaceTask = Task.detached(priority: .userInitiated) { scanner.scan(roots: roots) }.value
            async let dockerTask = Task.detached(priority: .utility) { docker.status() }.value
            let (newWorkspaces, newDockerState) = await (workspaceTask, dockerTask)
            workspaces = newWorkspaces
            dockerState = newDockerState
            selectedCandidateIDs = Set(newWorkspaces.flatMap(\.candidates).map(\.id))
            isScanning = false
        }
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

    func freeDiskSpace() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func saveRoots() {
        UserDefaults.standard.set(searchRoots.map(\.path), forKey: defaultsKey)
    }

    private static func defaultSearchRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let candidates = [
            home.appendingPathComponent(".codex/worktrees", isDirectory: true),
            home.appendingPathComponent("conductor/workspaces", isDirectory: true),
            home.appendingPathComponent("Developer", isDirectory: true),
            home.appendingPathComponent("Projects", isDirectory: true),
            home.appendingPathComponent("Documents/Eigene_Projekte", isDirectory: true)
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
