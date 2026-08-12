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

    func scanWorkspace(_ workspaceURL: URL) -> Workspace {
        let root = workspaceURL.standardizedFileURL
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
            branch: gitBranch(at: root),
            candidates: candidates.sorted { $0.allocatedBytes > $1.allocatedBytes }
        )
    }

    private func isGitWorkspace(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    private func gitBranch(at workspaceURL: URL) -> String {
        let marker = workspaceURL.appendingPathComponent(".git")
        var gitDirectory = marker
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory), !isDirectory.boolValue,
           let contents = try? String(contentsOf: marker, encoding: .utf8),
           contents.hasPrefix("gitdir:") {
            let rawPath = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: rawPath, relativeTo: workspaceURL).standardizedFileURL
        }

        let headURL = gitDirectory.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "Unknown branch"
        }

        if head.hasPrefix("ref: refs/heads/") {
            return String(head.dropFirst("ref: refs/heads/".count))
        }
        return "Detached · \(head.prefix(8))"
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
}
