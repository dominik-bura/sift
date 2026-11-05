import Darwin
import Foundation

/// Read-only metadata walker. No shell, file contents, symlink traversal, or
/// mount traversal. Every worker shares the same accounting ledger.
struct NativeStorageScanner: Sendable {
    var workers = 4
    var timeout: TimeInterval = 600
    var cache: NativeScanCache? = nil
    var metadataOnly = false

    enum ScanError: Error { case unsupported, malformedMetadata }
    struct Result: Codable, Sendable {
        let measurement: StorageMeasurement
        let children: [StorageMeasurement]
        let files: Int
        let directories: Int
        var cacheSafe = true
        var fingerprint = NativeFingerprint()
    }

    func measure(path: String, cancellation: CommandCancellation? = nil,
                 onProgress: @escaping @Sendable (StorageScanProgress) -> Void = { _ in }) throws -> Result {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        let state = NativeScanState(root: root, timeout: timeout, cancellation: cancellation, metadataOnly: metadataOnly, onProgress: onProgress)
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return state.result(rootBytes: nil, limited: true) }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { return state.result(rootBytes: nil, limited: true) }
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw ScanError.unsupported }
        let filesystemName = withUnsafeBytes(of: filesystem.f_fstypename) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        guard filesystemName == "apfs" else { throw ScanError.unsupported }
        let ticket = cancellation?.isCancelled == true ? nil : cache?.begin(root)
        if let ticket, let saved = cache?.candidate(ticket), !metadataOnly {
            let validation = try NativeStorageScanner(workers: workers, timeout: timeout, metadataOnly: true)
                .measure(path: root, cancellation: cancellation)
            if validation.measurement.isComplete, !validation.measurement.limitedAccess, validation.fingerprint == saved.fingerprint { return saved }
        }
        state.directoryOpened(root, metadata: metadata)
        let device = metadata.st_dev
        var jobs: [NativeEntry] = []
        var rootBytes = Int64(metadata.st_blocks) * 512
        var limited = false
        do {
            try NativeDirectory.read(fd: fd, extended: !metadataOnly, shouldStop: { state.stopped }) { entries in
                var files: [NativeEntry] = []
                for entry in entries {
                    if entry.error != 0 { limited = true; continue }
                    if entry.isDirectory { jobs.append(entry) }
                    else { files.append(entry) }
                }
                rootBytes += state.account(files, owner: NativeOwner(top: "", second: ""), directory: root)
            }
        } catch let error as ScanError { throw error }
        catch { limited = true }
        jobs.sort { $0.name < $1.name }
        let rootJobs = jobs
        let queue = NativeJobQueue(jobs: rootJobs)
        let group = DispatchGroup()
        let totalWorkers = min(4, max(1, workers))
        let rootWorkers = min(totalWorkers, max(1, rootJobs.count))
        state.prepareWorkers(spare: totalWorkers - rootWorkers)
        for _ in 0..<rootWorkers {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { state.releaseWorker(); group.leave() }
                while !state.stopped, let entry = queue.next() {
                    let child = root == "/" ? "/" + entry.name : root + "/" + entry.name
                    do {
                        let result = try Self.walk(parentFD: fd, entry: entry, path: child, top: child,
                            second: "", depth: 1, device: device, state: state)
                        state.finishTop(child, bytes: result.bytes, limited: result.limited)
                    } catch {
                        state.finishTop(child, bytes: 0, limited: true)
                        if error is ScanError { state.failNative() }
                    }
                }
            }
        }
        group.wait()
        if state.nativeFailed { throw ScanError.unsupported }
        let result = state.result(rootBytes: rootBytes, limited: limited)
        if let ticket { cache?.store(result, for: ticket) }
        return result
    }

    private static func walk(parentFD: Int32, entry: NativeEntry, path: String, top: String,
                             second: String, depth: Int, device: dev_t, state: NativeScanState) throws -> (bytes: Int64, limited: Bool) {
        guard !state.stopped, depth < 128 else { return (0, true) }
        let fd = entry.name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { return (0, true) }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { return (0, true) }
        guard metadata.st_dev == device else { return (0, false) } // Same-volume scope, like du -x.
        guard UInt64(metadata.st_ino) == entry.fileID else { return (0, true) }
        state.directoryOpened(path, metadata: metadata)
        let totals = NativeDirectoryTotals(bytes: Int64(metadata.st_blocks) * 512)
        let descendants = DispatchGroup()
        defer { descendants.wait() } // Keep parentFD alive, including error exits.
        do {
            try NativeDirectory.read(fd: fd, extended: !state.metadataOnly, shouldStop: { state.stopped }) { entries in
                var files: [NativeEntry] = []
                for child in entries {
                    if child.error != 0 { totals.add(0, limited: true); continue }
                    if child.isDirectory {
                        let childPath = path + "/" + child.name
                        let branch = depth == 1 ? childPath : second
                        let scanChild: @Sendable () -> Void = {
                            do {
                                let result = try walk(parentFD: fd, entry: child, path: childPath, top: top,
                                    second: branch, depth: depth + 1, device: device, state: state)
                                totals.add(result.bytes, limited: result.limited)
                                if depth == 1 { state.finishSecond(top: top, path: childPath, bytes: result.bytes) }
                            } catch {
                                totals.add(0, limited: true)
                                if error is ScanError { state.failNative() }
                            }
                        }
                        // Borrow an idle worker for a large single subtree.
                        // Never wait for a permit while holding a parent worker.
                        if depth <= 2, state.takeWorker() {
                            descendants.enter()
                            DispatchQueue.global(qos: .utility).async {
                                defer { state.releaseWorker(); descendants.leave() }
                                scanChild()
                            }
                        } else { scanChild() }
                    } else { files.append(child) }
                }
                totals.add(state.account(files, owner: NativeOwner(top: top, second: second), directory: path), limited: false)
            }
        } catch let error as ScanError { throw error }
        catch { totals.add(0, limited: true) }
        descendants.wait()
        state.directoryFinished(path)
        let result = totals.snapshot()
        return (result.bytes, result.limited || state.stopped)
    }
}

private struct NativeEntry: Sendable {
    let name: String
    let fileID: UInt64
    let device: UInt32
    let type: UInt32
    let links: UInt32
    let bytes: Int64
    let logicalBytes: Int64
    let cloneID: UInt64
    let fullyShared: Bool
    let error: UInt32
    let modifiedSeconds: UInt64
    let modifiedNanos: UInt64
    let changedSeconds: UInt64
    let changedNanos: UInt64
    var isDirectory: Bool { type == 2 } // VDIR from ATTR_CMN_OBJTYPE.
}

private enum NativeDirectory {
    static func read(fd: Int32, extended: Bool, shouldStop: () -> Bool, consume: ([NativeEntry]) throws -> Void) throws {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME)
        attributes.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH | ATTR_FILE_RSRCLENGTH | ATTR_FILE_RSRCALLOCSIZE)
        attributes.forkattr = extended ? attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS) : 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
        while !shouldStop() {
            let count = buffer.withUnsafeMutableBytes {
                getattrlistbulk(fd, &attributes, $0.baseAddress, $0.count, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            }
            if count == 0 { return }
            if count < 0 {
                if errno == ENOTSUP || errno == EINVAL { throw NativeStorageScanner.ScanError.unsupported }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let entries = try buffer.withUnsafeBytes { raw -> [NativeEntry] in
                var entries: [NativeEntry] = []
                var offset = 0
                for _ in 0..<count {
                    guard offset + 24 <= raw.count else { throw NativeStorageScanner.ScanError.malformedMetadata }
                    func u32(_ relative: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: offset + relative, as: UInt32.self) }
                    func u64(_ relative: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: offset + relative, as: UInt64.self) }
                    let length = Int(u32(0))
                    guard length >= 24, offset + length <= raw.count else { throw NativeStorageScanner.ScanError.malformedMetadata }
                    // Packed attributes use four-byte alignment, including UInt64.
                    // Filesystems omit unsupported fields; directory records do
                    // not have the same layout as regular-file records.
                    let common = u32(4), file = u32(16), extended = u32(20)
                    var cursor = 24
                    func take32(_ present: Bool) throws -> UInt32 {
                        guard present else { return 0 }
                        guard cursor + 4 <= length else { throw NativeStorageScanner.ScanError.malformedMetadata }
                        defer { cursor += 4 }; return u32(cursor)
                    }
                    func take64(_ present: Bool) throws -> UInt64 {
                        guard present else { return 0 }
                        guard cursor + 8 <= length else { throw NativeStorageScanner.ScanError.malformedMetadata }
                        defer { cursor += 8 }; return u64(cursor)
                    }
                    let error = try take32(common & attrgroup_t(ATTR_CMN_ERROR) != 0)
                    let reference = cursor
                    let nameRelative = try take32(common & attrgroup_t(ATTR_CMN_NAME) != 0)
                    let nameLength = Int(try take32(common & attrgroup_t(ATTR_CMN_NAME) != 0))
                    let device = try take32(common & attrgroup_t(ATTR_CMN_DEVID) != 0)
                    let type = try take32(common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0)
                    let modifiedSeconds = try take64(common & attrgroup_t(ATTR_CMN_MODTIME) != 0)
                    let modifiedNanos = try take64(common & attrgroup_t(ATTR_CMN_MODTIME) != 0)
                    let changedSeconds = try take64(common & attrgroup_t(ATTR_CMN_CHGTIME) != 0)
                    let changedNanos = try take64(common & attrgroup_t(ATTR_CMN_CHGTIME) != 0)
                    let fileID = try take64(common & attrgroup_t(ATTR_CMN_FILEID) != 0)
                    let links = try take32(file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0)
                    let bytes = try take64(file & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0)
                    let logical = try take64(file & attrgroup_t(ATTR_FILE_DATALENGTH) != 0)
                    let resourceLength = try take64(file & attrgroup_t(ATTR_FILE_RSRCLENGTH) != 0)
                    let resourceAllocation = try take64(file & attrgroup_t(ATTR_FILE_RSRCALLOCSIZE) != 0)
                    let cloneID = try take64(extended & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0)
                    let flags = try take64(extended & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0)
                    let nameOffset = reference + Int(Int32(bitPattern: nameRelative))
                    guard nameLength > 0, nameOffset >= cursor, nameOffset + nameLength <= length else { throw NativeStorageScanner.ScanError.malformedMetadata }
                    let name = String(decoding: raw[(offset + nameOffset)..<(offset + nameOffset + nameLength - 1)], as: UTF8.self)
                    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw NativeStorageScanner.ScanError.malformedMetadata }
                    let required = attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME)
                    let metadataMissing = common & required != required || (type != 2 && file & attrgroup_t(ATTR_FILE_ALLOCSIZE) == 0)
                    let flagsValid = extended & attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS) == attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
                    let resourceKnown = file & attrgroup_t(ATTR_FILE_RSRCLENGTH | ATTR_FILE_RSRCALLOCSIZE) == attrgroup_t(ATTR_FILE_RSRCLENGTH | ATTR_FILE_RSRCALLOCSIZE)
                    if type == 1, bytes > 0,
                       (file & attrgroup_t(ATTR_FILE_LINKCOUNT) == 0 || (attributes.forkattr != 0 && !flagsValid)) {
                        throw NativeStorageScanner.ScanError.unsupported
                    }
                    entries.append(NativeEntry(name: name, fileID: fileID, device: device, type: type,
                        links: links, bytes: max(0, Int64(bitPattern: bytes)), logicalBytes: max(0, Int64(bitPattern: logical)),
                        cloneID: flagsValid ? cloneID : 0,
                        // Conservatively retain whole-file allocation when
                        // resource forks exist, even if the data fork is cloned.
                        fullyShared: flagsValid && resourceKnown && resourceLength == 0 && resourceAllocation == 0 && flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0,
                        error: error != 0 ? error : metadataMissing ? UInt32(EIO) : 0,
                        modifiedSeconds: modifiedSeconds, modifiedNanos: modifiedNanos,
                        changedSeconds: changedSeconds, changedNanos: changedNanos))
                    offset += length
                }
                return entries
            }
            try consume(entries)
        }
    }
}

private struct NativeOwner: Comparable {
    let top: String
    let second: String
    static func < (a: Self, b: Self) -> Bool { a.top == b.top ? a.second < b.second : a.top < b.top }
}
private struct NativeIdentity: Hashable { let device: UInt32; let id: UInt64 }
private struct NativeCloneIdentity: Hashable { let device: UInt32; let id: UInt64; let logicalBytes: Int64; let allocatedBytes: Int64 }
private struct NativeSharedRecord {
    var owner: NativeOwner
    var bytes: Int64
    var clone: NativeCloneIdentity?
    var links: UInt32 = 1
    var references = 1
}

struct NativeFingerprint: Codable, Equatable, Sendable {
    var sum: UInt64 = 0
    var xor: UInt64 = 0
    var count: UInt64 = 0
    mutating func add(_ hash: Int) {
        let value = UInt64(truncatingIfNeeded: hash)
        sum &+= value; xor ^= value; count &+= 1
    }
    mutating func merge(_ other: Self) { sum &+= other.sum; xor ^= other.xor; count &+= other.count }
}

private final class NativeJobQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let jobs: [NativeEntry]
    private var index = 0
    init(jobs: [NativeEntry]) { self.jobs = jobs }
    func next() -> NativeEntry? {
        lock.lock(); defer { lock.unlock() }
        guard index < jobs.count else { return nil }
        defer { index += 1 }
        return jobs[index]
    }
}

private final class NativeDirectoryTotals: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64
    private var limited = false
    init(bytes: Int64) { self.bytes = bytes }
    func add(_ value: Int64, limited: Bool) { lock.lock(); self.bytes += value; self.limited = self.limited || limited; lock.unlock() }
    func snapshot() -> (bytes: Int64, limited: Bool) { lock.lock(); defer { lock.unlock() }; return (bytes, limited) }
}

private final class NativeScanState: @unchecked Sendable {
    private let lock = NSLock()
    private let workerBudget = DispatchSemaphore(value: 0)
    private let root: String
    private let started = Date()
    private let deadline: Date
    private let cancellation: CommandCancellation?
    private let onProgress: @Sendable (StorageScanProgress) -> Void
    private var shared: [NativeIdentity: NativeSharedRecord] = [:]
    private var tops: [String: Int64] = [:]
    private var seconds: [String: [String: Int64]] = [:]
    private var limitedTops = Set<String>()
    private var files = 0
    private var largeFiles = StorageFileSample()
    private var regularFileCount = 0
    private var directories = 0
    private var lastEmission = Date.distantPast
    private var failed = false
    private var fingerprint = NativeFingerprint()
    let metadataOnly: Bool
    init(root: String, timeout: TimeInterval, cancellation: CommandCancellation?, metadataOnly: Bool, onProgress: @escaping @Sendable (StorageScanProgress) -> Void) {
        self.root = root; self.deadline = Date().addingTimeInterval(timeout)
        self.cancellation = cancellation; self.onProgress = onProgress
        self.metadataOnly = metadataOnly
    }
    var stopped: Bool { cancellation?.isCancelled == true || Date() >= deadline || nativeFailed }
    func prepareWorkers(spare: Int) { for _ in 0..<spare { workerBudget.signal() } }
    func takeWorker() -> Bool { workerBudget.wait(timeout: .now()) == .success }
    func releaseWorker() { workerBudget.signal() }
    var nativeFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    func failNative() { lock.lock(); failed = true; lock.unlock() }
    func directoryOpened(_ path: String, metadata: stat) {
        var hash = Hasher()
        hash.combine(path); hash.combine(metadata.st_dev); hash.combine(metadata.st_ino)
        hash.combine(metadata.st_mtimespec.tv_sec); hash.combine(metadata.st_mtimespec.tv_nsec)
        hash.combine(metadata.st_ctimespec.tv_sec); hash.combine(metadata.st_ctimespec.tv_nsec)
        lock.lock(); fingerprint.add(hash.finalize()); lock.unlock()
    }
    func account(_ entries: [NativeEntry], owner: NativeOwner, directory: String) -> Int64 {
        var direct: Int64 = 0
        var signature = NativeFingerprint()
        for entry in entries {
            var hash = Hasher()
            hash.combine(owner.top); hash.combine(owner.second); hash.combine(entry.name)
            hash.combine(entry.fileID); hash.combine(entry.device); hash.combine(entry.type)
            hash.combine(entry.links); hash.combine(entry.bytes); hash.combine(entry.logicalBytes)
            hash.combine(entry.modifiedSeconds); hash.combine(entry.modifiedNanos)
            hash.combine(entry.changedSeconds); hash.combine(entry.changedNanos)
            signature.add(hash.finalize())
        }
        lock.lock(); defer { lock.unlock() }
        fingerprint.merge(signature)
        for entry in entries {
            files += 1
            if !metadataOnly, entry.type == 1 {
                regularFileCount += 1
                // Bounded retention: never keep every path in dependency trees.
                // Ranking is by file allocation, independently of shared-folder
                // attribution; these rows must never be summed as savings.
                largeFiles.consider(bytes: entry.bytes, logicalBytes: entry.logicalBytes, shared: entry.links > 1 || entry.fullyShared,
                    path: (directory == "/" ? "" : directory) + "/" + entry.name)
            }
            if !metadataOnly && (entry.links > 1 || (entry.fullyShared && entry.cloneID != 0)) {
                let inode = NativeIdentity(device: entry.device, id: entry.fileID)
                let clone = entry.fullyShared && entry.cloneID != 0 ? NativeCloneIdentity(device: entry.device, id: entry.cloneID, logicalBytes: entry.logicalBytes, allocatedBytes: entry.bytes) : nil
                if var existing = shared[inode] {
                    existing.owner = min(existing.owner, owner)
                    existing.bytes = max(existing.bytes, entry.bytes)
                    existing.links = max(existing.links, entry.links)
                    existing.references += 1
                    if clone != existing.clone { existing.clone = nil }
                    shared[inode] = existing
                } else { shared[inode] = NativeSharedRecord(owner: owner, bytes: entry.bytes, clone: clone, links: entry.links) }
            } else { direct += entry.bytes }
        }
        return direct
    }
    func directoryFinished(_ path: String) {
        lock.lock(); directories += 1
        if Date().timeIntervalSince(lastEmission) >= 0.2 { emit(path) }
        lock.unlock()
    }
    func finishSecond(top: String, path: String, bytes: Int64) {
        lock.lock(); seconds[top, default: [:]][path] = bytes; lock.unlock()
    }
    func finishTop(_ path: String, bytes: Int64, limited: Bool) {
        lock.lock(); tops[path] = bytes
        if limited { limitedTops.insert(path) }
        if Date().timeIntervalSince(lastEmission) >= 0.2 { emit(path) }
        lock.unlock()
    }
    private func emit(_ current: String) {
        lastEmission = Date()
        let folders = tops.map { StorageFolder(path: $0.key, bytes: $0.value, limitedAccess: limitedTops.contains($0.key) ? true : nil) }.sorted { $0.bytes > $1.bytes }
        onProgress(StorageScanProgress(path: root, startedAt: started, completedDirectories: directories,
            currentPath: current, folders: folders, children: [], totalBytes: nil, largeFiles: largeFiles.sorted, fileCount: regularFileCount))
    }
    func result(rootBytes: Int64?, limited: Bool) -> NativeStorageScanner.Result {
        lock.lock(); defer { lock.unlock() }
        var direct = rootBytes ?? 0
        var byClone: [NativeCloneIdentity: NativeSharedRecord] = [:]
        func add(_ record: NativeSharedRecord) {
            if record.owner.top.isEmpty { direct += record.bytes }
            else {
                tops[record.owner.top, default: 0] += record.bytes
                if !record.owner.second.isEmpty { seconds[record.owner.top, default: [:]][record.owner.second, default: 0] += record.bytes }
            }
        }
        for record in shared.values {
            if let clone = record.clone {
                if var previous = byClone[clone] {
                    previous.owner = min(previous.owner, record.owner)
                    previous.bytes = max(previous.bytes, record.bytes)
                    byClone[clone] = previous
                } else { byClone[clone] = record }
            } else { add(record) }
        }
        for record in byClone.values { add(record) }
        let cancelled = cancellation?.isCancelled == true
        let timedOut = Date() >= deadline
        let incomplete = cancelled || timedOut || rootBytes == nil
        if rootBytes != nil { directories += 1 }
        let date = Date()
        let folders = tops.map { StorageFolder(path: $0.key, bytes: $0.value, limitedAccess: limitedTops.contains($0.key) ? true : nil) }.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
        let measurement = StorageMeasurement(path: root, folders: folders, totalBytes: incomplete ? nil : direct + folders.reduce(0) { $0 + $1.bytes },
            date: date, limitedAccess: limited || !limitedTops.isEmpty || incomplete, timedOut: timedOut, cancelled: cancelled,
            accounting: "native-shared-v1", accountingScope: root,
            largeFiles: metadataOnly ? nil : largeFiles.sorted, fileCount: metadataOnly ? nil : regularFileCount)
        let children = folders.filter { !limitedTops.contains($0.path) && !incomplete }.map { folder in
            StorageMeasurement(path: folder.path, folders: (seconds[folder.path] ?? [:]).map { StorageFolder(path: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes },
                totalBytes: folder.bytes, date: date, limitedAccess: measurement.limitedAccess, timedOut: false,
                accounting: "native-shared-v1", accountingScope: root)
        }
        onProgress(StorageScanProgress(path: root, startedAt: started, completedDirectories: directories, currentPath: root,
            folders: folders, children: children, totalBytes: measurement.totalBytes, largeFiles: measurement.largeFiles, fileCount: measurement.fileCount))
        // Writes through a hardlink outside the watched root may not generate
        // an event under this root. Never reuse such a scan as a live cache.
        let cacheSafe = !shared.values.contains { Int($0.links) > $0.references }
        return NativeStorageScanner.Result(measurement: measurement, children: children, files: files, directories: directories, cacheSafe: cacheSafe, fingerprint: fingerprint)
    }
}
