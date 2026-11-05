import Foundation

struct StorageScanProgress: Sendable {
    let path: String
    let startedAt: Date
    let completedDirectories: Int
    let currentPath: String?
    let folders: [StorageFolder]
    let children: [StorageMeasurement]
    let totalBytes: Int64?
    var activeFolder: StorageFolder? = nil
    var largeFiles: [StorageFile]? = nil
    var fileCount: Int? = nil

    /// Keep old rows visible until their replacement arrives. An in-flight
    /// measurement never has a total: residuals must not imply completed work.
    func displaying(over previous: StorageMeasurement?) -> StorageMeasurement {
        var rows = Dictionary((previous?.folders ?? []).map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
        for folder in folders { rows[folder.path] = folder }
        let oldOrder = previous?.folders.map(\.path) ?? []
        let ordered = oldOrder.compactMap { rows.removeValue(forKey: $0) } + rows.values.sorted { $0.bytes > $1.bytes }
        return StorageMeasurement(path: path, folders: ordered,
                                  totalBytes: nil, date: previous?.date ?? startedAt,
                                  limitedAccess: previous?.limitedAccess ?? false, timedOut: false,
                                  largeFiles: largeFiles ?? previous?.largeFiles, fileCount: fileCount ?? previous?.fileCount)
    }
}

/// du emits a line when a directory finishes. Consume all directory lines,
/// retaining only the first two levels, so memory doesn't grow with file count.
final class StorageScanAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let root: String
    private let startedAt = Date()
    private var count = 0
    private var current: String?
    private var total: Int64?
    private var children: [String: Int64] = [:]
    private var grandchildren: [String: [String: Int64]] = [:]
    private var lastEmission = Date.distantPast
    private var active: StorageFolder?

    init(path: String) { root = path }

    func consume(_ line: String, onProgress: @Sendable (StorageScanProgress) -> Void) {
        guard let entry = Self.entry(line), entry.path == root || entry.path.hasPrefix(root == "/" ? "/" : root + "/") else { return }
        lock.lock(); defer { lock.unlock() }
        count += 1
        current = entry.path
        if entry.path != root {
            let prefix = root == "/" ? "/" : root + "/"
            if let component = entry.path.dropFirst(prefix.count).split(separator: "/").first {
                let top = prefix + component
                if children[top] == nil {
                    active = StorageFolder(path: top, bytes: max(active?.path == top ? active!.bytes : 0, entry.bytes))
                }
            }
        }
        let parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent().path
        if entry.path == root { total = entry.bytes }
        else if parent == root { children[entry.path] = entry.bytes; active = nil }
        else if URL(fileURLWithPath: parent).deletingLastPathComponent().path == root {
            grandchildren[parent, default: [:]][entry.path] = entry.bytes
        }
        if Date().timeIntervalSince(lastEmission) >= 0.25 || parent == root || entry.path == root {
            lastEmission = Date()
            onProgress(snapshotLocked())
        }
    }

    func snapshot() -> StorageScanProgress {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }

    private func snapshotLocked() -> StorageScanProgress {
        let folders = children.map { StorageFolder(path: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
        let measured = folders.map { folder in
            StorageMeasurement(path: folder.path,
                               folders: (grandchildren[folder.path] ?? [:]).map { StorageFolder(path: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes },
                               totalBytes: folder.bytes, date: Date(), limitedAccess: true, timedOut: false)
        }
        return StorageScanProgress(path: root, startedAt: startedAt, completedDirectories: count,
                                   currentPath: current, folders: folders, children: measured, totalBytes: total,
                                   activeFolder: active)
    }

    static func entry(_ line: String) -> StorageFolder? {
        guard let tab = line.firstIndex(of: "\t"), let kb = Int64(line[..<tab]),
              kb >= 0, kb <= Int64.max / 1024 else { return nil }
        return StorageFolder(path: String(line[line.index(after: tab)...]), bytes: kb * 1024)
    }
}
