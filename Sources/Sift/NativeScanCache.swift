import CoreServices
import Darwin
import Foundation

/// Session-only, event-validated cache. Persisted measurements remain history,
/// not trusted live cache entries after a restart or an event-stream failure.
final class NativeScanCache: @unchecked Sendable {
    static let shared = NativeScanCache()
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let capacity: Int
    private let lifetime: TimeInterval
    init(capacity: Int = 8, lifetime: TimeInterval = 300) { self.capacity = capacity; self.lifetime = lifetime }
    private struct Entry {
        let watch: NativeRootWatch
        var result: NativeStorageScanner.Result?
        var generation: UInt64 = 0
        var storedAt = Date.distantPast
        var revision: NativeRootRevision?
    }
    struct Ticket {
        fileprivate let path: String
        fileprivate let watch: NativeRootWatch
        fileprivate let generation: UInt64
        fileprivate let revision: NativeRootRevision
    }
    func begin(_ path: String) -> Ticket? {
        lock.lock()
        if entries[path] == nil {
            guard let watch = NativeRootWatch(path: path) else { lock.unlock(); return nil }
            if entries.count >= max(1, capacity), let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
                entries[oldest] = nil
            }
            entries[path] = Entry(watch: watch)
        }
        let watch = entries[path]!.watch
        lock.unlock()
        guard let generation = watch.validatedGeneration() else {
            lock.lock()
            if entries[path]?.watch === watch { entries[path] = nil }
            lock.unlock()
            return nil
        }
        guard let revision = NativeRootRevision.read(path) else { return nil }
        return Ticket(path: path, watch: watch, generation: generation, revision: revision)
    }
    /// A candidate, not proof of freshness. The scanner must compare a fresh
    /// recursive metadata fingerprint before returning any cached totals.
    func candidate(_ ticket: Ticket) -> NativeStorageScanner.Result? {
        guard let generation = ticket.watch.validatedGeneration(), generation == ticket.generation,
              NativeRootRevision.read(ticket.path) == ticket.revision else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[ticket.path], entry.watch === ticket.watch,
              entry.generation == generation, entry.revision == ticket.revision, Date().timeIntervalSince(entry.storedAt) < lifetime,
              let saved = entry.result else { return nil }
        var measurement = saved.measurement
        measurement.cached = true
        let children = saved.children.map { child -> StorageMeasurement in
            var child = child; child.cached = true; return child
        }
        return NativeStorageScanner.Result(measurement: measurement, children: children, files: saved.files, directories: saved.directories, cacheSafe: saved.cacheSafe, fingerprint: saved.fingerprint)
    }
    func store(_ result: NativeStorageScanner.Result, for ticket: Ticket) {
        guard result.cacheSafe, result.measurement.isComplete, !result.measurement.limitedAccess,
              let generation = ticket.watch.validatedGeneration(), generation == ticket.generation,
              NativeRootRevision.read(ticket.path) == ticket.revision else { return }
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[ticket.path], entry.watch === ticket.watch else { return }
        entry.result = result; entry.generation = generation; entry.storedAt = Date()
        entry.revision = ticket.revision
        entries[ticket.path] = entry
    }
    func invalidate(_ path: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        for key in Array(entries.keys) where path == nil || StorageOverviewService.scansOverlap(key, path!) {
            entries[key]?.result = nil
            entries[key]?.watch.invalidate()
        }
    }
}

private final class NativeWatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var reliable = true
    func changed(flags: FSEventStreamEventFlags) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        // Dropped events, moved roots, and volume changes invalidate the lease
        // entirely. A subsequent request must obtain a new watch and rescan.
        let failures = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped |
            kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount)
        if flags & failures != 0 { reliable = false }
    }
    func value() -> UInt64? { lock.lock(); defer { lock.unlock() }; return reliable ? generation : nil }
}

/// An inexpensive extra hint, not a freshness proof: recursive generation
/// counters can remain unchanged after a nested file-content write.
fileprivate struct NativeRootRevision: Equatable {
    let device: dev_t
    let inode: ino_t
    let generation: UInt64
    static func read(_ path: String) -> Self? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { return nil }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_RECURSIVE_GENCOUNT)
        var buffer = [UInt8](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBytes {
            fgetattrlist(fd, &attributes, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            guard raw.loadUnaligned(as: UInt32.self) >= 32,
                  raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self) & attrgroup_t(ATTR_CMNEXT_RECURSIVE_GENCOUNT) != 0 else { return nil }
            return Self(device: metadata.st_dev, inode: metadata.st_ino, generation: raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
        }
    }
}

fileprivate final class NativeRootWatch: @unchecked Sendable {
    private let state = NativeWatchState()
    private let queue = DispatchQueue(label: "sift.storage-cache-events", qos: .utility)
    private var stream: FSEventStreamRef?
    init?(path: String) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(state).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info else { return }
            let state = Unmanaged<NativeWatchState>.fromOpaque(info).takeUnretainedValue()
            for index in 0..<count { state.changed(flags: flags[index]) }
        }
        let canonicalPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let stream = FSEventStreamCreate(nil, callback, &context, [canonicalPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil
            return nil
        }
    }
    func validatedGeneration() -> UInt64? {
        guard let stream else { return nil }
        FSEventStreamFlushSync(stream)
        queue.sync { }
        return state.value()
    }
    func invalidate() { state.changed(flags: 0) }
    deinit {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
            queue.sync { }
            FSEventStreamRelease(stream)
        }
    }
}
