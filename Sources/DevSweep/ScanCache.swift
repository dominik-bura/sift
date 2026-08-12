import Foundation

struct ScanCache: Sendable {
    private var fileManager: FileManager { .default }
    private let cacheURL: URL

    init(cacheURL: URL? = nil) {
        let fileManager = FileManager.default
        if let cacheURL {
            self.cacheURL = cacheURL
        } else {
            let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.cacheURL = base.appendingPathComponent("DevSweep/scan-cache.json")
        }
    }

    func load(under roots: [URL]) -> [Workspace] {
        guard let data = try? Data(contentsOf: cacheURL),
              let records = try? JSONDecoder().decode([WorkspaceRecord].self, from: data) else { return [] }
        let rootPaths = roots.map { $0.standardizedFileURL.path }

        return records.compactMap { record in
            let workspaceURL = URL(fileURLWithPath: record.path, isDirectory: true).standardizedFileURL
            guard rootPaths.contains(where: { workspaceURL.path == $0 || workspaceURL.path.hasPrefix($0 + "/") }),
                  fileManager.fileExists(atPath: workspaceURL.path) else { return nil }

            let candidates = record.candidates.compactMap { candidate -> CleanupCandidate? in
                let url = URL(fileURLWithPath: candidate.path, isDirectory: true).standardizedFileURL
                guard let kind = CleanupKind.byDirectoryName[url.lastPathComponent],
                      url.path.hasPrefix(workspaceURL.path + "/"),
                      fileManager.fileExists(atPath: url.path) else { return nil }
                return CleanupCandidate(
                    url: url,
                    kind: kind,
                    allocatedBytes: candidate.allocatedBytes,
                    modificationDate: candidate.modificationDate
                )
            }
            guard !candidates.isEmpty else { return nil }
            return Workspace(
                url: workspaceURL,
                name: record.name,
                branch: record.branch,
                repositoryID: record.repositoryID,
                repositoryName: record.repositoryName,
                candidates: candidates
            )
        }
    }

    func save(_ workspaces: [Workspace]) {
        let records = workspaces.map(WorkspaceRecord.init)
        guard let data = try? JSONEncoder().encode(records) else { return }
        do {
            try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            return
        }
    }
}

private struct WorkspaceRecord: Codable {
    let path: String
    let name: String
    let branch: String
    let repositoryID: String
    let repositoryName: String
    let candidates: [CandidateRecord]

    init(_ workspace: Workspace) {
        path = workspace.url.path
        name = workspace.name
        branch = workspace.branch
        repositoryID = workspace.repositoryID
        repositoryName = workspace.repositoryName
        candidates = workspace.candidates.map(CandidateRecord.init)
    }
}

private struct CandidateRecord: Codable {
    let path: String
    let allocatedBytes: Int64
    let modificationDate: Date?

    init(_ candidate: CleanupCandidate) {
        path = candidate.url.path
        allocatedBytes = candidate.allocatedBytes
        modificationDate = candidate.modificationDate
    }
}
