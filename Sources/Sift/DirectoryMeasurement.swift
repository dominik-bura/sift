import Darwin
import Foundation

/// Folder-attributed size plus the newest modification date found inside.
/// The date is a write time, not a last-use time: reading a cached file does
/// not update it. Directory dates are included because adding or removing an
/// entry updates its parent even when extracted files keep archive timestamps.
struct DirectoryMeasurement: Equatable, Sendable {
    var bytes: Int64 = 0
    var newestChange: Date?

    mutating func add(_ other: DirectoryMeasurement) {
        bytes += other.bytes
        if let date = other.newestChange, date > (newestChange ?? .distantPast) { newestChange = date }
    }

    /// Returns nil when any part of the tree could not be read, so a partial
    /// total is never presented as a measured size. A missing path measures as empty.
    ///
    /// Walks with fts(3), the same traversal `du` uses: one `lstat` per entry and
    /// no per-file URL objects, which matters for caches holding hundreds of
    /// thousands of small files. Symbolic links are never followed and the walk
    /// stays on one volume.
    static func measure(_ url: URL, now: Date = Date()) -> DirectoryMeasurement? {
        var rootInfo = stat()
        guard lstat(url.path, &rootInfo) == 0 else { return errno == ENOENT ? DirectoryMeasurement() : nil }
        guard let path = strdup(url.path) else { return nil }
        defer { free(path) }
        let arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let stream = arguments.withUnsafeBufferPointer({ fts_open($0.baseAddress!, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) }) else { return nil }
        defer { fts_close(stream) }

        var result = DirectoryMeasurement()
        var failed = false
        // Dates in the future come from broken clocks or archives; ignoring them
        // keeps one odd file from marking a cache as permanently in use.
        let latestPlausible = Int(now.timeIntervalSince1970) + 60
        var newest = Int.min
        var countedLinks = Set<FileIdentity>()
        while let entry = fts_read(stream) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_F:
                guard let info = entry.pointee.fts_statp?.pointee else { failed = true; continue }
                // A file hard-linked twice inside the tree occupies its blocks once.
                if info.st_nlink > 1, !countedLinks.insert(FileIdentity(device: info.st_dev, inode: info.st_ino)).inserted { continue }
                result.bytes += Int64(info.st_blocks) * 512
                if info.st_mtimespec.tv_sec <= latestPlausible { newest = max(newest, info.st_mtimespec.tv_sec) }
            case FTS_D:
                guard let info = entry.pointee.fts_statp?.pointee else { failed = true; continue }
                if info.st_mtimespec.tv_sec <= latestPlausible { newest = max(newest, info.st_mtimespec.tv_sec) }
            case FTS_DNR, FTS_ERR, FTS_NS:
                failed = true
            default:
                break // Post-order directories, symbolic links, and special files.
            }
        }
        // fts_read sets errno to 0 when the whole hierarchy was returned.
        if errno != 0 { failed = true }
        if newest != Int.min { result.newestChange = Date(timeIntervalSince1970: TimeInterval(newest)) }
        return failed ? nil : result
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }
}
