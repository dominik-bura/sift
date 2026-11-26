import Foundation

/// Main-actor-owned reservations: independent jobs may overlap in time, never
/// on the same source or on ancestor/descendant data paths.
struct CleanupActivity {
    struct Job {
        let paths: [String]
        var overlapped = false
    }
    private(set) var jobs: [String: Job] = [:]
    var isEmpty: Bool { jobs.isEmpty }

    func canStart(_ id: String, paths: [String]) -> Bool {
        guard jobs[id] == nil else { return false }
        let paths = paths.map(Self.canonicalPath)
        return !jobs.values.contains { job in
            job.paths.contains { left in paths.contains { right in
                let a = left, b = right
                return a == b || a == "/" || b == "/" || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
            } }
        }
    }
    @discardableResult mutating func begin(_ id: String, paths: [String]) -> Bool {
        guard canStart(id, paths: paths) else { return false }
        let overlapped = !jobs.isEmpty
        for key in Array(jobs.keys) { jobs[key]?.overlapped = true }
        jobs[id] = Job(paths: paths.map(Self.canonicalPath), overlapped: overlapped)
        return true
    }
    mutating func finish(_ id: String) { jobs.removeValue(forKey: id) }
    private static func canonicalPath(_ path: String) -> String {
        // Only already-known cleanup targets, never broad disk traversal.
        var prefix = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        // Foundation can leave a nonexistent leaf unresolved. Resolve its
        // existing ancestor so a deleting job still owns missing descendants.
        while prefix.path != "/", !FileManager.default.fileExists(atPath: prefix.path) {
            missing.append(prefix.lastPathComponent)
            prefix.deleteLastPathComponent()
        }
        let resolved = missing.reversed().reduce(prefix.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        return StoragePrivacyPolicy.canonical(resolved.path)
    }
}

/// Injectable execution boundary lets concurrency tests use gates instead of
/// running destructive commands against the developer's actual caches.
struct CleanupExecution: Sendable {
    var cleanCache: @Sendable (String) async throws -> Void
    var inspectCache: @Sendable (String) async -> GlobalCache?
    var pruneDocker: @Sendable () async throws -> String
    var inspectDocker: @Sendable () async -> DockerState
    static var live: Self {
        Self(cleanCache: { try GlobalCacheService().clean(id: $0) },
             inspectCache: { GlobalCacheService().inspectAfterCleanup(id: $0) },
             pruneDocker: { try DockerService().pruneUnusedData() },
             inspectDocker: { DockerService().status() })
    }
}
