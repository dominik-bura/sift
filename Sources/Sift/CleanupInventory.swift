import Foundation

enum CacheCategory: String, CaseIterable, Identifiable {
    case packages = "Packages", apps = "Apps", developerTools = "Developer tools"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .packages: "shippingbox"; case .apps: "square.grid.2x2"; case .developerTools: "hammer" }
    }
    var detail: String {
        switch self {
        case .packages: "Package-manager caches and downloaded dependencies"
        case .apps: "App caches only · profiles and conversations stay protected"
        case .developerTools: "Build data, provider plugins, simulators, and Docker"
        }
    }
    static func containing(_ cache: GlobalCache) -> Self {
        switch cache.id {
        case "uv", "pnpm", "bun", "yarn", "npm", "homebrew": .packages
        case "dia-cache", "codex-cache", "spark-cache": .apps
        default: .developerTools
        }
    }
}

struct CleanupInventory {
    struct Segment: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
    }
    let worktreeBytes: Int64
    let caches: [GlobalCache]
    let docker: DockerState
    var worktreesUnmeasured = false

    func caches(in category: CacheCategory) -> [GlobalCache] {
        caches.filter { CacheCategory.containing($0) == category }.sorted {
            if $0.bytes == $1.bytes { return $0.name < $1.name }
            return $0.bytes > $1.bytes
        }
    }
    func storedBytes(in category: CacheCategory) -> Int64 { caches(in: category).reduce(0) { $0 + $1.bytes } }
    var isMeasuring: Bool { worktreesUnmeasured || caches.contains { $0.state == .checking } }
    var hasUnmeasuredSources: Bool {
        worktreesUnmeasured || caches.contains {
            switch $0.state { case .checking, .failed, .unavailable: true; default: false }
        }
    }
    var segments: [Segment] {
        [Segment(id: "worktrees", name: "Worktrees", bytes: worktreeBytes)] + CacheCategory.allCases.map {
            Segment(id: $0.id, name: $0.rawValue, bytes: storedBytes(in: $0))
        }
    }
    // Docker's reclaimable estimate is a different quantity. Never add it to
    // folder-attributed bytes or portray this inventory as a disk-usage total.
    var storedBytes: Int64 { segments.reduce(0) { $0 + $1.bytes } }
    var dockerEstimate: Int64? {
        if case let .available(bytes, _) = docker { return bytes }
        return nil
    }
}

struct CleanupObservation {
    let operation: String
    let date: Date
    let freeSpaceChange: Int64?
    let movedToTrash: Bool

    init(operation: String, before: Int64?, after: Int64?, movedToTrash: Bool = false, date: Date = Date()) {
        self.operation = operation
        self.date = date
        self.movedToTrash = movedToTrash
        if let before, let after { freeSpaceChange = after - before } else { freeSpaceChange = nil }
    }
}
