import Foundation

enum CleanupSafetyError: LocalizedError, Equatable {
    case unsupportedDirectory(String)
    case outsideWorkspace
    case workspaceItself
    case symbolicLink
    case missingDirectory

    var errorDescription: String? {
        switch self {
        case let .unsupportedDirectory(name): return "\(name) is not an approved generated directory."
        case .outsideWorkspace: return "The directory is outside its workspace."
        case .workspaceItself: return "A workspace can never be deleted."
        case .symbolicLink: return "Symbolic links are not cleaned."
        case .missingDirectory: return "The directory no longer exists."
        }
    }
}

struct CleanupService: Sendable {
    private var fileManager: FileManager { FileManager.default }

    func validate(candidate: CleanupCandidate, in workspace: Workspace) throws {
        let target = candidate.url.standardizedFileURL
        let root = workspace.url.standardizedFileURL

        guard target != root else { throw CleanupSafetyError.workspaceItself }
        guard target.path.hasPrefix(root.path + "/") else { throw CleanupSafetyError.outsideWorkspace }
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

        var removed: [CleanupCandidate] = []
        var failed: [(CleanupCandidate, String)] = []

        for candidate in candidates {
            guard let workspace = workspaceByCandidate[candidate.id] else {
                failed.append((candidate, CleanupSafetyError.outsideWorkspace.localizedDescription))
                continue
            }

            do {
                try validate(candidate: candidate, in: workspace)
                try fileManager.removeItem(at: candidate.url)
                removed.append(candidate)
            } catch {
                failed.append((candidate, error.localizedDescription))
            }
        }

        return CleanupResult(removed: removed, failed: failed)
    }
}
