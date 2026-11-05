import Darwin
import XCTest
@testable import Sift

final class NativeStorageScannerTests: XCTestCase {
    func testWarmCacheBenchmarkWhenExplicitlyRequested() throws {
        guard let destination = ProcessInfo.processInfo.environment["SIFT_CACHE_BENCHMARK"] else { throw XCTSkip("Opt-in cache benchmark") }
        let scanner = NativeStorageScanner(timeout: 30, cache: NativeScanCache())
        var records: [[String: Any]] = []
        for path in [NSHomeDirectory() + "/.cache/uv", NSHomeDirectory() + "/.codex/worktrees"] {
            for round in 1...3 {
                let start = Date()
                let result = try scanner.measure(path: path)
                records.append(["path": path, "round": round, "seconds": Date().timeIntervalSince(start),
                                "cached": result.measurement.cached ?? false, "limited": result.measurement.limitedAccess,
                                "cache_safe": result.cacheSafe, "bytes": result.measurement.totalBytes.map { $0 as Any } ?? NSNull()])
                try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: destination), options: .atomic)
            }
        }
    }
    func testBenchmarkWhenExplicitlyRequested() throws {
        guard let destination = ProcessInfo.processInfo.environment["SIFT_NATIVE_BENCHMARK"] else { throw XCTSkip("Opt-in read-only benchmark") }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let targets = [repository.appendingPathComponent(".build").path, NSHomeDirectory() + "/.cache/uv", NSHomeDirectory() + "/.codex/worktrees"]
        let mole = ["/opt/homebrew/opt/mole/libexec/bin/analyze-go", "/usr/local/opt/mole/libexec/bin/analyze-go"].first { FileManager.default.isExecutableFile(atPath: $0) }
        var records: [[String: Any]] = []
        for round in 1...2 {
            for path in targets {
                for engine in (round == 1 ? ["du", "native", "mole"] : ["mole", "native", "du"]) {
                    let start = Date()
                    var row: [String: Any] = ["path": path, "engine": engine, "round": round]
                    if engine == "native" {
                        let result = try NativeStorageScanner(timeout: 30).measure(path: path)
                        row["bytes"] = result.measurement.totalBytes.map { $0 as Any } ?? NSNull()
                        row["limited"] = result.measurement.limitedAccess
                        row["accounting"] = result.measurement.accounting
                        row["files"] = result.files
                        row["directories"] = result.directories
                        row["cache_safe"] = result.cacheSafe
                    } else if engine == "du" {
                        let token = CommandCancellation()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { token.cancel() }
                        let result = StorageOverviewService().measureTree(path: path, cancellation: token, engine: .du)
                        row["bytes"] = result.measurement.totalBytes.map { $0 as Any } ?? NSNull()
                        row["limited"] = result.measurement.limitedAccess
                    } else {
                        guard let mole else { continue }
                        let result = SecureCommandRunner().run(URL(fileURLWithPath: mole), arguments: ["--json", path], timeout: 30)
                        row["result"] = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) ?? NSNull()
                        row["exit"] = result.exitCode
                    }
                    row["seconds"] = Date().timeIntervalSince(start)
                    records.append(row)
                    try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: destination), options: .atomic)
                    print("NATIVE BENCHMARK \(engine) \(URL(fileURLWithPath: path).lastPathComponent) \(row["seconds"]!)s")
                }
            }
        }
    }
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-native-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testNativeOrdinaryTreeMatchesAllocatedDUAndPreservesNestedChildren() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("child/grandchild")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 17, count: 32_768).write(to: folder.appendingPathComponent("regular.bin"))
        let native = try NativeStorageScanner().measure(path: root.path)
        let du = StorageOverviewService().measureTree(path: root.path, engine: .du)
        XCTAssertEqual(native.measurement.totalBytes, du.measurement.totalBytes)
        XCTAssertFalse(native.measurement.limitedAccess)
        XCTAssertEqual(native.measurement.folders, du.measurement.folders)
        XCTAssertEqual(native.children.first?.folders.first?.path, folder.path)
        XCTAssertEqual(native.measurement.accounting, "native-shared-v1")
    }
    func testCloneHardlinkAndSparseAccountingAcrossWorkers() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let original = root.appendingPathComponent("c/original.bin")
        try Data(repeating: 51, count: 1_048_576).write(to: original)
        let clone = root.appendingPathComponent("b/clone.bin")
        let copied = original.path.withCString { source in clone.path.withCString { clonefile(source, $0, 0) } }
        guard copied == 0 else { throw XCTSkip("Filesystem does not support clonefile") }
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("a/hardlink.bin"))
        let sparse = root.appendingPathComponent("sparse.bin")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let file = try FileHandle(forWritingTo: sparse)
        try file.truncate(atOffset: 1_073_741_824)
        try file.close()
        let serial = try NativeStorageScanner(workers: 1).measure(path: root.path)
        let parallel = try NativeStorageScanner(workers: 4).measure(path: root.path)
        XCTAssertEqual(parallel.measurement.totalBytes, 1_048_576)
        XCTAssertEqual(serial.measurement.folders, parallel.measurement.folders, "Sharing ownership must be deterministic, not depend on worker order")
        XCTAssertEqual(serial.fingerprint, parallel.fingerprint)
        XCTAssertEqual(parallel.measurement.folders.reduce(0) { $0 + $1.bytes }, 1_048_576)
    }
    func testDeniedFolderIsPartialAndSymlinkIsNotFollowed() throws {
        let root = try fixture()
        let outside = try fixture()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("denied").path)
            try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let denied = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 65_536).write(to: denied.appendingPathComponent("private"))
        try Data(repeating: 2, count: 1_048_576).write(to: outside.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        let result = try NativeStorageScanner().measure(path: root.path)
        XCTAssertTrue(result.measurement.limitedAccess)
        XCTAssertEqual(result.measurement.folders.first(where: { $0.path == denied.path })?.limitedAccess, true)
        XCTAssertLessThan(result.measurement.totalBytes ?? Int64.max, 65_536)
    }
    func testCancelledScanHasNoCompletedTotalAndDoesNotStartFallback() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = CommandCancellation(); token.cancel()
        let result = StorageOverviewService().measureTree(path: root.path, cancellation: token, engine: .native)
        XCTAssertTrue(result.measurement.cancelled == true)
        XCTAssertNil(result.measurement.totalBytes)
        XCTAssertEqual(result.measurement.accounting, "native-shared-v1")
    }

    func testChangingACloneDoesNotCollapseDifferentData() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let clone = root.appendingPathComponent("clone")
        try Data(repeating: 1, count: 1_048_576).write(to: source)
        let copied = source.path.withCString { src in clone.path.withCString { clonefile(src, $0, 0) } }
        guard copied == 0 else { throw XCTSkip("clonefile unsupported") }
        let handle = try FileHandle(forWritingTo: clone)
        try handle.write(contentsOf: Data(repeating: 2, count: 4_096))
        try handle.close()
        let measurement = try NativeStorageScanner().measure(path: root.path).measurement
        XCTAssertGreaterThan(try XCTUnwrap(measurement.totalBytes), 1_048_576, "Partially shared clones must not be treated as fully identical extents")
    }

    func testCacheInvalidatesNestedEditsAndExplicitRefresh() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("data")
        try Data(repeating: 3, count: 4_096).write(to: file)
        let cache = NativeScanCache()
        let scanner = NativeStorageScanner(cache: cache)
        let first = try scanner.measure(path: root.path)
        var cached = try scanner.measure(path: root.path)
        // Initial creation events may arrive while the first scan commits.
        // That scan must be discarded, not trusted just to make this test fast.
        for _ in 0..<50 where cached.measurement.cached != true {
            Thread.sleep(forTimeInterval: 0.01)
            cached = try scanner.measure(path: root.path)
        }
        XCTAssertEqual(cached.measurement.cached, true)
        XCTAssertEqual(first.measurement.totalBytes, cached.measurement.totalBytes)
        // Modify only file contents: no parent-directory mtime changes.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 4, count: 65_536))
        try handle.close()
        let edited = try scanner.measure(path: root.path)
        XCTAssertNotEqual(edited.measurement.cached, true)
        XCTAssertGreaterThan(try XCTUnwrap(edited.measurement.totalBytes), try XCTUnwrap(first.measurement.totalBytes))
        cache.invalidate(root.path)
        XCTAssertNotEqual(try scanner.measure(path: root.path).measurement.cached, true)
    }

    func testLimitedResultsNeverBecomeCacheEntriesAndAccountingChangesAreNotGrowth() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = NativeScanCache()
        guard let ticket = cache.begin(root.path) else { throw XCTSkip("FSEvents unavailable") }
        let partial = StorageMeasurement(path: root.path, folders: [], totalBytes: 0, date: Date(), limitedAccess: true, timedOut: false)
        cache.store(NativeStorageScanner.Result(measurement: partial, children: [], files: 0, directories: 0), for: ticket)
        XCTAssertNil(cache.candidate(ticket))
        var native = partial
        native.accounting = "native-shared-v1"; native.accountingScope = root.path
        XCTAssertFalse(partial.comparable(to: native))
        var otherScope = native; otherScope.accountingScope = "/another/root"
        XCTAssertFalse(native.comparable(to: otherScope))
    }

    func testExternalHardlinkWritesAreNeverHiddenByCache() throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let file = root.appendingPathComponent("data"), alias = outside.appendingPathComponent("alias")
        try Data(repeating: 1, count: 4_096).write(to: file)
        try FileManager.default.linkItem(at: file, to: alias)
        let scanner = NativeStorageScanner(cache: NativeScanCache())
        let first = try scanner.measure(path: root.path)
        XCTAssertFalse(first.cacheSafe)
        let handle = try FileHandle(forWritingTo: alias)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 2, count: 65_536)); try handle.close()
        let second = try scanner.measure(path: root.path)
        XCTAssertNotEqual(second.measurement.cached, true)
        XCTAssertGreaterThan(try XCTUnwrap(second.measurement.totalBytes), try XCTUnwrap(first.measurement.totalBytes))
    }

    func testPermissionChangesInvalidateCachedResults() throws {
        let root = try fixture()
        let child = root.appendingPathComponent("child")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: child.appendingPathComponent("file"))
        let scanner = NativeStorageScanner(cache: NativeScanCache())
        _ = try scanner.measure(path: root.path)
        _ = try scanner.measure(path: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: child.path)
        let denied = try scanner.measure(path: root.path)
        XCTAssertTrue(denied.measurement.limitedAccess)
        XCTAssertNotEqual(denied.measurement.cached, true)
    }

    func testUnsupportedNativeMetadataFallsBackToDU() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 65_536).write(to: root.appendingPathComponent("file"))
        let service = StorageOverviewService(nativeScan: { _, _, _, _ in throw NativeStorageScanner.ScanError.unsupported })
        let result = service.measureTree(path: root.path)
        XCTAssertEqual(result.measurement.totalBytes, 65_536)
        XCTAssertNil(result.measurement.accounting)
        XCTAssertFalse(result.measurement.limitedAccess)
    }

    func testDifferentFullySharedCloneGroupsAreNotMergedAfterCopyOnWrite() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), changed = root.appendingPathComponent("changed")
        try Data(repeating: 1, count: 1_048_576).write(to: original)
        func clone(_ source: URL, _ destination: URL) throws {
            let result = source.path.withCString { src in destination.path.withCString { clonefile(src, $0, 0) } }
            guard result == 0 else { throw XCTSkip("clonefile unsupported") }
        }
        try clone(original, changed)
        let handle = try FileHandle(forWritingTo: changed)
        try handle.write(contentsOf: Data(repeating: 2, count: 4_096)); try handle.close()
        try clone(original, root.appendingPathComponent("original-copy"))
        try clone(changed, root.appendingPathComponent("changed-copy"))
        let result = try NativeStorageScanner().measure(path: root.path)
        XCTAssertGreaterThan(try XCTUnwrap(result.measurement.totalBytes), 1_048_576)
    }

    func testResourceForkAllocationsAreConservativeRatherThanDeduplicated() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original"), clone = root.appendingPathComponent("clone")
        try Data(repeating: 1, count: 65_536).write(to: source)
        do { try Data(repeating: 2, count: 4_096).write(to: URL(fileURLWithPath: source.path + "/..namedfork/rsrc")) }
        catch { throw XCTSkip("Resource forks unsupported") }
        let copied = source.path.withCString { src in clone.path.withCString { clonefile(src, $0, 0) } }
        guard copied == 0 else { throw XCTSkip("clonefile unsupported") }
        try Data(repeating: 3, count: 4_096).write(to: URL(fileURLWithPath: clone.path + "/..namedfork/rsrc"))
        let native = try NativeStorageScanner().measure(path: root.path)
        let du = StorageOverviewService().measureTree(path: root.path, engine: .du)
        XCTAssertEqual(native.measurement.totalBytes, du.measurement.totalBytes)
    }
}
