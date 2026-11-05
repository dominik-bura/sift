import Foundation
import XCTest
@testable import Sift

private func snapshot(_ path: String, bytes: Int64 = 100, date: Date = Date(), limited: Bool = false) -> StorageMeasurement {
    StorageMeasurement(path: path, folders: [StorageFolder(path: path + "/child", bytes: bytes)],
        totalBytes: bytes, date: date, limitedAccess: limited, timedOut: false)
}

private final class ScanFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    private var released = Set<String>()
    private var active = 0
    private var peak = 0
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return started }
    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func release(_ path: String) { lock.lock(); defer { lock.unlock() }; released.insert(path) }
    func run(_ path: String, _ token: CommandCancellation, _ progress: @Sendable (StorageScanProgress) -> Void) -> (measurement: StorageMeasurement, children: [StorageMeasurement]) {
        lock.lock(); started.append(path); active += 1; peak = max(peak, active); lock.unlock()
        let folder = StorageFolder(path: path + "/finished", bytes: 10)
        progress(StorageScanProgress(path: path, startedAt: Date(), completedDirectories: 1,
            currentPath: folder.path, folders: [folder], children: [], totalBytes: nil))
        let deadline = Date().addingTimeInterval(5)
        while !token.isCancelled, Date() < deadline {
            lock.lock(); let done = released.contains(path); lock.unlock()
            if done { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        lock.lock(); active -= 1; lock.unlock()
        return (StorageMeasurement(path: path, folders: [folder], totalBytes: token.isCancelled ? nil : 10,
            date: Date(), limitedAccess: token.isCancelled, timedOut: false, cancelled: token.isCancelled), [])
    }
}

final class StorageSchedulingTests: XCTestCase {
    private func temporaryStore() -> StorageHistoryStore {
        StorageHistoryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("Sift-scheduling-\(UUID())/history.json"))
    }
    @MainActor private func until(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for fixture scan")
    }

    func testRunnerCancellationDoesNotBecomeTimeout() async {
        let token = CommandCancellation()
        let start = Date()
        let task = Task.detached {
            SecureCommandRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 15, cancellation: token)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        token.cancel()
        let result = await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, -3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let skipped = SecureCommandRunner().run(URL(fileURLWithPath: "/does-not-exist"), arguments: [], cancellation: token)
        XCTAssertTrue(skipped.cancelled)
        let normal = SecureCommandRunner().run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        XCTAssertEqual(normal.exitCode, 0)
        XCTAssertFalse(normal.cancelled)
    }

    @MainActor func testSerialQueuePrioritizesSmallFoldersAndCancelsWaitingRequests() async {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        store.save(["/small": snapshot("/small", bytes: 1), "/large": snapshot("/large", bytes: 1000)])
        let fixture = ScanFixture()
        let model = StorageOverviewModel(store: store, measure: fixture.run)
        model.scan("/first", force: true)
        await until { fixture.paths.count == 1 }
        model.scan(StorageOverviewService.rootPath, force: true)
        model.scan("/large", force: true)
        model.scan("/small", force: true)
        model.scan("/small", force: true)
        model.scan("/skip", force: true)
        model.cancel("/skip")
        XCTAssertEqual(model.queuedPaths, ["/small", "/large", StorageOverviewService.rootPath])
        fixture.release("/first")
        await until { fixture.paths.count == 2 }
        XCTAssertEqual(fixture.paths, ["/first", "/small"])
        model.cancel("/small")
        await until { fixture.paths.count == 3 }
        fixture.release("/large")
        await until { fixture.paths.count == 4 }
        model.cancel(StorageOverviewService.rootPath)
        await until { model.scanningPaths.isEmpty }
        XCTAssertEqual(fixture.maxActive, 1)
        XCTAssertFalse(fixture.paths.contains("/skip"))
    }

    @MainActor func testCancellationPreservesBaselineAndCompletedRowsAcrossRestart() async {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let old = snapshot("/root", bytes: 500, date: Date().addingTimeInterval(-86_400))
        store.save([old.path: old])
        let fixture = ScanFixture()
        let model = StorageOverviewModel(store: store, measure: fixture.run)
        model.scan(old.path, force: true)
        await until { model.progress[old.path]?.completedDirectories == 1 }
        model.cancel(old.path)
        await until { model.scanningPaths.isEmpty }
        XCTAssertEqual(model.measurements[old.path]?.totalBytes, 500)
        XCTAssertEqual(model.partialMeasurements[old.path]?.folders.count, 2)
        XCTAssertNil(model.partialMeasurements[old.path]?.totalBytes)
        XCTAssertEqual(model.partialMeasurements[old.path]?.cancelled, true)
        XCTAssertEqual(model.snapshots[old.path]?.count, 1)
        let restarted = StorageOverviewModel(store: store)
        XCTAssertEqual(restarted.measurements[old.path]?.totalBytes, 500)
        XCTAssertEqual(restarted.partialMeasurements[old.path]?.cancelled, true)
        XCTAssertNil(restarted.growthBaseline(for: old.path))
    }

    @MainActor func testParentResultSatisfiesQueuedChildWithoutExtraWalk() async {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let fixture = ScanFixture()
        let model = StorageOverviewModel(store: store, measure: { path, token, progress in
            let result = fixture.run(path, token, progress)
            return (result.measurement, [snapshot("/root/child")])
        })
        model.scan("/root", force: true)
        await until { fixture.paths.count == 1 }
        model.scan("/root/child", force: true)
        fixture.release("/root")
        await until { model.scanningPaths.isEmpty }
        XCTAssertTrue(model.queuedPaths.isEmpty)
        XCTAssertEqual(fixture.paths, ["/root"])
        XCTAssertNotNil(model.measurements["/root/child"])
    }

    @MainActor func testLegacyHistoryMigrationAndPersistentDatedBaseline() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let now = Date()
        let old = snapshot("/root", date: now.addingTimeInterval(-10 * 86_400))
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([old.path: old]).write(to: store.url)
        let migrated = StorageOverviewModel(store: store)
        XCTAssertEqual(migrated.snapshots[old.path]?.first?.date, old.date)
        let current = snapshot(old.path, bytes: 200, date: now)
        let recent = snapshot(old.path, bytes: 190, date: now.addingTimeInterval(-86_400))
        let limited = snapshot(old.path, date: now.addingTimeInterval(-8 * 86_400), limited: true)
        store.saveArchive(StorageHistoryArchive(latest: [old.path: current], snapshots: [old.path: [old, limited, recent, current]]))
        let restarted = StorageOverviewModel(store: store)
        XCTAssertEqual(restarted.growthBaseline(for: old.path)?.date, old.date)
        XCTAssertFalse(store.loadArchive().snapshots[old.path]!.contains { $0.limitedAccess })
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
