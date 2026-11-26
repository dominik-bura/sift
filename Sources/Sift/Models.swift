import Foundation

struct CleanupKind: Hashable, Sendable {
    let directoryName: String
    let label: String
    let symbolName: String
    /// Shown next to the folder when removing it has a consequence beyond a rebuild.
    var note: String? = nil

    static let supported: [CleanupKind] = [
        .init(directoryName: "node_modules", label: "Node dependencies", symbolName: "shippingbox"),
        .init(directoryName: ".next", label: "Next.js cache", symbolName: "bolt"),
        .init(directoryName: ".venv", label: "Python environment", symbolName: "chevron.left.forwardslash.chevron.right"),
        .init(directoryName: "venv", label: "Python environment", symbolName: "chevron.left.forwardslash.chevron.right"),
        .init(directoryName: ".turbo", label: "Turborepo cache", symbolName: "gauge.with.dots.needle.67percent"),
        .init(directoryName: ".parcel-cache", label: "Parcel cache", symbolName: "shippingbox"),
        .init(directoryName: ".pytest_cache", label: "Pytest cache", symbolName: "checkmark.seal"),
        .init(directoryName: ".mypy_cache", label: "mypy cache", symbolName: "checkmark.bubble"),
        .init(directoryName: ".ruff_cache", label: "Ruff cache", symbolName: "wind"),
        .init(directoryName: "__pycache__", label: "Python bytecode", symbolName: "doc.badge.gearshape"),
        .init(directoryName: ".svelte-kit", label: "SvelteKit output", symbolName: "flame"),
        .init(directoryName: ".angular", label: "Angular cache", symbolName: "a.circle"),
        .init(directoryName: ".vite", label: "Vite cache", symbolName: "bolt.circle"),
        .init(directoryName: ".nx", label: "Nx cache", symbolName: "square.stack.3d.up"),
        .init(directoryName: ".nuxt", label: "Nuxt output", symbolName: "mountain.2"),
        .init(directoryName: ".output", label: "Framework output", symbolName: "shippingbox"),
        .init(directoryName: ".astro", label: "Astro cache", symbolName: "sparkles"),
        .init(directoryName: ".docusaurus", label: "Docusaurus cache", symbolName: "book.closed"),
        .init(directoryName: ".expo", label: "Expo cache", symbolName: "app.badge"),
        .init(directoryName: ".tox", label: "tox environments", symbolName: "testtube.2"),
        .init(directoryName: ".nox", label: "nox environments", symbolName: "testtube.2"),
        .init(directoryName: "target", label: "Rust build output", symbolName: "hammer"),
        .init(directoryName: ".gradle", label: "Gradle project cache", symbolName: "hammer.circle"),
        .init(directoryName: ".dart_tool", label: "Dart tool cache", symbolName: "wrench.and.screwdriver"),
        .init(directoryName: ".build", label: "Swift build output", symbolName: "swift"),
        .init(directoryName: "coverage", label: "Coverage reports", symbolName: "chart.bar"),
        .init(directoryName: "Pods", label: "CocoaPods dependencies", symbolName: "shippingbox"),
        .init(directoryName: ".terraform", label: "Terraform providers and modules", symbolName: "square.stack.3d.down.right",
              note: "Needs terraform init afterwards · the selected workspace resets to default"),
        .init(directoryName: ".pnpm-store", label: "Project pnpm store", symbolName: "shippingbox.fill")
    ]

    static let byDirectoryName = Dictionary(uniqueKeysWithValues: supported.map { ($0.directoryName, $0) })
}

struct CleanupCandidate: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let kind: CleanupKind
    let allocatedBytes: Int64
    let conservativeBytes: Int64
    let modificationDate: Date?

    init(
        url: URL,
        kind: CleanupKind,
        allocatedBytes: Int64,
        conservativeBytes: Int64? = nil,
        modificationDate: Date? = nil
    ) {
        self.url = url
        self.kind = kind
        self.allocatedBytes = allocatedBytes
        self.conservativeBytes = conservativeBytes ?? allocatedBytes
        self.modificationDate = modificationDate
    }
}

struct WorkspaceScanResult: Sendable {
    let workspace: Workspace
    let reusedSizeCount: Int
    let measuredSizeCount: Int
    let duration: TimeInterval
}

struct Workspace: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let branch: String
    let repositoryID: String
    let repositoryName: String
    let candidates: [CleanupCandidate]

    var reclaimableBytes: Int64 {
        candidates.reduce(0) { $0 + $1.allocatedBytes }
    }

    var conservativeReclaimableBytes: Int64 {
        candidates.reduce(0) { $0 + $1.conservativeBytes }
    }
}

struct RepositoryGroup: Identifiable, Hashable, Sendable {
    var id: String { repositoryID }
    let repositoryID: String
    let name: String
    let workspaces: [Workspace]

    var reclaimableBytes: Int64 {
        workspaces.reduce(0) { $0 + $1.reclaimableBytes }
    }
}

enum DockerState: Equatable, Sendable {
    case checking
    case unavailable(String)
    case available(reclaimableBytes: Int64, detail: String)

    var reclaimableBytes: Int64 {
        if case let .available(bytes, _) = self { return bytes }
        return 0
    }
}

struct GlobalCache: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case checking
        case unavailable
        case available(bytes: Int64, path: String)
        case blocked(bytes: Int64, path: String, processCount: Int)
        case failed(String)
        var path: String? {
            switch self {
            case let .available(_, path), let .blocked(_, path, _): return path
            default: return nil
            }
        }
    }

    let id: String
    let name: String
    let detail: String
    let symbolName: String
    let state: State
    /// Newest modification date found inside the cache. This is a write time,
    /// not a last-use time: reading a cached file does not update it.
    var lastChanged: Date? = nil

    var bytes: Int64 {
        if case let .available(bytes, _) = state { return bytes }
        if case let .blocked(bytes, _, _) = state { return bytes }
        return 0
    }

    var measuredBytes: Int64? {
        switch state {
        case let .available(bytes, _), let .blocked(bytes, _, _): bytes
        default: nil
        }
    }

    var onlyPrunesUnusedData: Bool {
        id == "pnpm" || id == "homebrew" || id == "simulators"
    }
    // Provider plugins, unavailable simulator devices, other pnpm stores, and
    // file-based sources that opt out are explicit individual reviews.
    var includedInCleanAll: Bool {
        if let definition = RegenerableCacheService.definition(id: id) { return definition.includedInCleanAll }
        return id != "pulumi" && id != "simulators" && id != GlobalCacheService.otherPnpmStoresID
    }
    /// Sources whose folders are removed entirely, so a later inspection finds nothing.
    var disappearsWhenEmpty: Bool {
        if id == GlobalCacheService.otherPnpmStoresID { return true }
        return RegenerableCacheService.definition(id: id)?.targets.contains { $0.removal == .item } == true
    }

    /// A cache written within this window is probably still in use.
    static let recentChangeInterval: TimeInterval = 14 * 86_400

    func changedRecently(now: Date = Date()) -> Bool {
        guard let lastChanged else { return false }
        return now.timeIntervalSince(lastChanged) < Self.recentChangeInterval
    }
    /// Clearing a cache that is still being written mostly causes the same
    /// data to download again, so bulk cleanup leaves it for individual review.
    /// Prune-only sources keep what is in use and are unaffected.
    func skippedByBulkCleanup(now: Date = Date()) -> Bool {
        // Leftovers with their own age rule (update downloads, job logs) are
        // not caches in use: whatever is still recent was already left out.
        if RegenerableCacheService.definition(id: id)?.minimumAge != nil { return false }
        return !onlyPrunesUnusedData && changedRecently(now: now)
    }
    func lastChangedLabel(now: Date = Date()) -> String? {
        guard let lastChanged, bytes > 0 else { return nil }
        if now.timeIntervalSince(lastChanged) < 60 { return "Changed just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return "Changed " + formatter.localizedString(for: lastChanged, relativeTo: now)
    }

    var reclaimableBytes: Int64 {
        onlyPrunesUnusedData ? 0 : bytes
    }
}

struct CleanupResult: Sendable {
    let trashed: [CleanupCandidate]
    let trashedURLs: [URL]
    let failed: [(CleanupCandidate, String)]

    var reclaimedBytes: Int64 {
        trashed.reduce(0) { $0 + $1.allocatedBytes }
    }
}

enum ByteFormatting {
    static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: max(0, bytes))
    }
}
