import Foundation

struct WorkspaceScanner: Sendable {
    private var fileManager: FileManager { FileManager.default }

    func scan(roots: [URL]) -> [Workspace] {
        discoverWorkspaces(in: roots)
            .map(scanWorkspace)
            .filter { !$0.candidates.isEmpty }
            .sorted {
                if $0.reclaimableBytes == $1.reclaimableBytes { return $0.name < $1.name }
                return $0.reclaimableBytes > $1.reclaimableBytes
            }
    }

    func usesShallowDiscovery(for root: URL) -> Bool {
        Self.isKnownWorkspaceRoot(root)
    }

    func discoverWorkspaces(in roots: [URL]) -> [URL] {
        var found = Set<URL>()

        for rawRoot in roots {
            let root = rawRoot.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            if isGitWorkspace(root) {
                found.insert(root)
                continue
            }

            if Self.isKnownWorkspaceRoot(root) {
                found.formUnion(discoverWorkspaces(inKnownRoot: root, maximumDepth: 2))
                continue
            }

            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let item = enumerator.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true else { continue }

                if values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }

                if Self.discoveryExcludedNames.contains(item.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }

                if isGitWorkspace(item) {
                    found.insert(item.standardizedFileURL)
                    enumerator.skipDescendants()
                }
            }
        }

        return found.sorted { $0.path < $1.path }
    }

    private func discoverWorkspaces(inKnownRoot root: URL, maximumDepth: Int) -> Set<URL> {
        var found = Set<URL>()
        var queue: [(URL, Int)] = [(root, 0)]

        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard depth < maximumDepth,
                  let children = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if isGitWorkspace(child) { found.insert(child.standardizedFileURL) }
                else { queue.append((child, depth + 1)) }
            }
        }
        return found
    }

    func scanWorkspace(_ workspaceURL: URL) -> Workspace {
        let root = workspaceURL.standardizedFileURL
        let git = gitMetadata(at: root)
        var candidates: [CleanupCandidate] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]

        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) {
            while let item = enumerator.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true else { continue }

                if values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }

                let name = item.lastPathComponent
                if name == ".git" {
                    enumerator.skipDescendants()
                    continue
                }

                if let kind = CleanupKind.byDirectoryName[name] {
                    candidates.append(
                        CleanupCandidate(
                            url: item.standardizedFileURL,
                            kind: kind,
                            allocatedBytes: allocatedSize(of: item)
                        )
                    )
                    enumerator.skipDescendants()
                }
            }
        }

        return Workspace(
            url: root,
            name: root.lastPathComponent,
            branch: git.branch,
            repositoryID: git.commonDirectory.path,
            repositoryName: git.repositoryName,
            candidates: candidates.sorted { $0.allocatedBytes > $1.allocatedBytes }
        )
    }

    private func isGitWorkspace(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    private func gitMetadata(at workspaceURL: URL) -> (branch: String, commonDirectory: URL, repositoryName: String) {
        let marker = workspaceURL.appendingPathComponent(".git")
        var gitDirectory = marker
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory), !isDirectory.boolValue,
           let contents = try? String(contentsOf: marker, encoding: .utf8),
           contents.hasPrefix("gitdir:") {
            let rawPath = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: rawPath, relativeTo: workspaceURL).standardizedFileURL
        }

        var commonDirectory = gitDirectory
        let commonDirectoryMarker = gitDirectory.appendingPathComponent("commondir")
        if let rawCommonDirectory = try? String(contentsOf: commonDirectoryMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawCommonDirectory.isEmpty {
            commonDirectory = URL(fileURLWithPath: rawCommonDirectory, relativeTo: gitDirectory).standardizedFileURL
        }

        let repositoryRoot = commonDirectory.lastPathComponent == ".git"
            ? commonDirectory.deletingLastPathComponent()
            : workspaceURL
        let repositoryName = repositoryRoot.lastPathComponent

        let headURL = gitDirectory.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return ("Unknown branch", commonDirectory, repositoryName)
        }

        if head.hasPrefix("ref: refs/heads/") {
            return (String(head.dropFirst("ref: refs/heads/".count)), commonDirectory, repositoryName)
        }
        return ("Detached · \(head.prefix(8))", commonDirectory, repositoryName)
    }

    private func allocatedSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private static let discoveryExcludedNames: Set<String> = [
        ".git", "node_modules", ".next", ".venv", "venv", ".turbo", ".parcel-cache",
        ".pytest_cache", ".mypy_cache", ".ruff_cache", "__pycache__", ".svelte-kit", ".angular", ".vite",
        "Library", ".Trash"
    ]

    private static func isKnownWorkspaceRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return knownWorkspaceRootSuffixes.contains { path.hasSuffix($0) }
    }

    private static let knownWorkspaceRootSuffixes = [
        "/.codex/worktrees", "/claude/worktrees", "/.claude/worktrees", "/.cursor/worktrees",
        "/.t3/worktrees", "/.superset/worktrees", "/.superconductor/worktrees",
        "/conductor/workspaces", "/.copilot/workspaces", "/.21st/worktrees"
    ]
}
