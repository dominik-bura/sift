import Foundation

struct CleanupKind: Hashable, Sendable {
    let directoryName: String
    let label: String
    let symbolName: String

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
        .init(directoryName: ".vite", label: "Vite cache", symbolName: "bolt.circle")
    ]

    static let byDirectoryName = Dictionary(uniqueKeysWithValues: supported.map { ($0.directoryName, $0) })
}

struct CleanupCandidate: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let kind: CleanupKind
    let allocatedBytes: Int64
}

struct Workspace: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let branch: String
    let candidates: [CleanupCandidate]

    var reclaimableBytes: Int64 {
        candidates.reduce(0) { $0 + $1.allocatedBytes }
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

struct CleanupResult: Sendable {
    let removed: [CleanupCandidate]
    let failed: [(CleanupCandidate, String)]

    var reclaimedBytes: Int64 {
        removed.reduce(0) { $0 + $1.allocatedBytes }
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
