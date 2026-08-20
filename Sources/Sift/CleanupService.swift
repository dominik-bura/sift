import Foundation

protocol TrashServing: Sendable {
    func trashItem(at url: URL) throws -> URL
}

struct SystemTrashService: TrashServing {
    func trashItem(at url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else {
            throw CocoaError(.fileWriteUnknown)
        }
        return resultingURL as URL
    }
}

enum CleanupSafetyError: LocalizedError, Equatable {
    case unsupportedDirectory(String)
    case outsideWorkspace
    case workspaceItself
    case symbolicLink
    case missingDirectory
    case invalidWorkspace

    var errorDescription: String? {
        switch self {
        case let .unsupportedDirectory(name): return "\(name) is not an approved generated directory."
        case .outsideWorkspace: return "The directory is outside its workspace."
        case .workspaceItself: return "A workspace can never be deleted."
        case .symbolicLink: return "Symbolic links are not cleaned."
        case .missingDirectory: return "The directory no longer exists."
        case .invalidWorkspace: return "The workspace is no longer a Git worktree."
        }
    }
}

struct CleanupService: Sendable {
    private var fileManager: FileManager { FileManager.default }
    private let trashService: any TrashServing

    init(trashService: any TrashServing = SystemTrashService()) {
        self.trashService = trashService
    }

    func validate(candidate: CleanupCandidate, in workspace: Workspace) throws {
        let target = candidate.url.standardizedFileURL
        let root = workspace.url.standardizedFileURL

        guard target != root else { throw CleanupSafetyError.workspaceItself }
        guard target.path.hasPrefix(root.path + "/") else { throw CleanupSafetyError.outsideWorkspace }
        guard fileManager.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            throw CleanupSafetyError.invalidWorkspace
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedTarget.path.hasPrefix(resolvedRoot.path + "/") else { throw CleanupSafetyError.outsideWorkspace }
        guard CleanupKind.byDirectoryName[target.lastPathComponent] != nil else {
            throw CleanupSafetyError.unsupportedDirectory(target.lastPathComponent)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CleanupSafetyError.missingDirectory
        }

        let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CleanupSafetyError.symbolicLink }
    }

    func remove(_ candidates: [CleanupCandidate], from workspaces: [Workspace]) -> CleanupResult {
        let workspaceByCandidate = Dictionary(
            uniqueKeysWithValues: workspaces.flatMap { workspace in
                workspace.candidates.map { ($0.id, workspace) }
            }
        )

        var trashed: [CleanupCandidate] = []
        var trashedURLs: [URL] = []
        var failed: [(CleanupCandidate, String)] = []

        for candidate in candidates {
            guard let workspace = workspaceByCandidate[candidate.id] else {
                failed.append((candidate, CleanupSafetyError.outsideWorkspace.localizedDescription))
                continue
            }

            do {
                try validate(candidate: candidate, in: workspace)
                // Revalidate at the last possible moment to narrow path-swap races.
                try validate(candidate: candidate, in: workspace)
                let trashURL = try trashService.trashItem(at: candidate.url)
                trashed.append(candidate)
                trashedURLs.append(trashURL)
            } catch {
                failed.append((candidate, error.localizedDescription))
            }
        }

        return CleanupResult(trashed: trashed, trashedURLs: trashedURLs, failed: failed)
    }
}
