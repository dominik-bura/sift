import Foundation
import XCTest
@testable import Sift

final class StorageOverviewTests: XCTestCase {
    func testDUParserSeparatesTotalAndChildrenAndFlagsPartialAccess() {
        let command = CommandResult(output: "12\t/example/folder with spaces\n9\t/example/second\n21\t/example\ninvalid\n", error: "Permission denied", exitCode: 1, timedOut: false)
        let result = StorageOverviewService.parse(command, path: "/example")
        XCTAssertEqual(result.totalBytes, 21 * 1024)
        XCTAssertEqual(result.folders.map(\.bytes), [12 * 1024, 9 * 1024])
        XCTAssertEqual(result.folders.first?.path, "/example/folder with spaces")
        XCTAssertTrue(result.limitedAccess)
        XCTAssertEqual(result.volumeDifference(usedBytes: 20 * 1024), -1024)
    }

    func testTimedOutScanCannotClaimVolumeDifference() {
        let result = StorageOverviewService.parse(CommandResult(output: "1\t/example\n", error: "timeout", exitCode: -2, timedOut: true), path: "/example")
        XCTAssertNil(result.volumeDifference(usedBytes: 100))
    }

    func testMemoryGroupingIncludesChildrenWithoutLoopingOrOtherApps() {
        let rows = MemoryService.parse("10 1 100\n11 10 200\n12 11 300\n20 1 900\ninvalid\n")
        XCTAssertEqual(MemoryService.groupedBytes(root: 10, processes: rows), 600 * 1024)
        XCTAssertEqual(MemoryService.groupedBytes(root: 20, processes: rows), 900 * 1024)
    }

    func testExplicitCleanupItemsExcludedFromCleanAll() {
        for id in ["pulumi", "simulators"] {
            let cache = GlobalCache(id: id, name: id, detail: "", symbolName: "", state: .available(bytes: 1024, path: "/example"))
            XCTAssertFalse(cache.includedInCleanAll)
        }
    }

    func testCacheCleanupPreservesHistoryAndRejectsRedirectedDirectory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-cache-test-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/Codex")
        let history = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: cache.appendingPathComponent("data"))
        try Data("keep".utf8).write(to: history.appendingPathComponent("session.jsonl"))
        let service = RegenerableCacheService(home: home, runningAppNames: { [] })
        try service.clean(id: "codex-cache")
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.appendingPathComponent("session.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: history)
        XCTAssertThrowsError(try service.clean(id: "codex-cache"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.appendingPathComponent("session.jsonl").path))
    }

    func testRunningAppBlocksCacheCleanup() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-running-test-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = RegenerableCacheService(home: home, runningAppNames: { ["Dia"] })
        XCTAssertThrowsError(try service.clean(id: "dia-cache"))
    }

    func testStorageHistoryRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-history-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StorageHistoryStore(url: folder.appendingPathComponent("history.json"))
        let snapshot = StorageOverviewService.parse(CommandResult(output: "7\t/example\n", error: "", exitCode: 0, timedOut: false), path: "/example")
        store.save([snapshot.path: snapshot])
        XCTAssertEqual(store.load()[snapshot.path]?.totalBytes, 7 * 1024)
    }
}
