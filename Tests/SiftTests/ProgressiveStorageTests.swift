import Foundation
import XCTest
@testable import Sift

private final class RecordedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, Date)] = []
    func append(_ line: String) { lock.lock(); defer { lock.unlock() }; entries.append((line, Date())) }
    var values: [(String, Date)] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class ProgressiveStorageTests: XCTestCase {
    func testRelatedPathsDoNotStartDuplicateDiskWalks() {
        XCTAssertTrue(StorageOverviewService.scansOverlap("/root", "/root/child"))
        XCTAssertTrue(StorageOverviewService.scansOverlap("/root/child", "/root"))
        XCTAssertTrue(StorageOverviewService.scansOverlap("/", "/root"))
        XCTAssertFalse(StorageOverviewService.scansOverlap("/root", "/root-other"))
        XCTAssertFalse(StorageOverviewService.scansOverlap("/root/a", "/root/b"))
    }
    func testStreamingRunnerPublishesBeforeCommandFinishesAndKeepsUnicode() {
        let lines = RecordedLines()
        let result = SecureCommandRunner().run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'first\\n'; /bin/sleep 0.3; printf '\\303'; /bin/sleep 0.05; printf '\\251\\nlast'"],
            timeout: 3, captureOutput: false, onOutputLine: { lines.append($0) })
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(lines.values.map(\.0), ["first", "é", "last"])
        XCTAssertGreaterThan(lines.values[1].1.timeIntervalSince(lines.values[0].1), 0.15)
    }

    func testProgressKeepsOldRowsAndNeverClaimsCompletedTotal() {
        let old = StorageMeasurement(path: "/root", folders: [StorageFolder(path: "/root/old", bytes: 1_024)],
                                     totalBytes: 1_024, date: Date(), limitedAccess: false, timedOut: false)
        let progress = StorageScanProgress(path: "/root", startedAt: Date(), completedDirectories: 2, currentPath: nil,
                                           folders: [StorageFolder(path: "/root/new", bytes: 2_048)], children: [], totalBytes: 3_072)
        let display = progress.displaying(over: old)
        XCTAssertEqual(display.folders.map(\.path), ["/root/old", "/root/new"])
        XCTAssertNil(display.totalBytes)
        XCTAssertNil(display.volumeDifference(usedBytes: 10_000))
    }

    func testAccumulatorRetainsCompletedChildrenAndMarksActiveLowerBound() {
        let accumulator = StorageScanAccumulator(path: "/root")
        accumulator.consume("5\t/root/a/one/deep", onProgress: { _ in })
        accumulator.consume("8\t/root/a/one", onProgress: { _ in })
        XCTAssertEqual(accumulator.snapshot().activeFolder, StorageFolder(path: "/root/a", bytes: 8 * 1_024))
        accumulator.consume("12\t/root/a", onProgress: { _ in })
        accumulator.consume("100\t/outside", onProgress: { _ in })
        accumulator.consume("-1\t/root/b", onProgress: { _ in })
        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.completedDirectories, 3)
        XCTAssertNil(snapshot.activeFolder)
        XCTAssertEqual(snapshot.folders.count, 1)
        XCTAssertEqual(snapshot.children.first?.totalBytes, 12 * 1_024)
        XCTAssertEqual(snapshot.children.first?.folders, [StorageFolder(path: "/root/a/one", bytes: 8 * 1_024)])
        XCTAssertNil(snapshot.totalBytes)
    }

    func testRealScanMatchesDUAndReusesNestedMeasurements() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-progress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let nested = fixture.appendingPathComponent("child/grandchild")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 32_768).write(to: nested.appendingPathComponent("fixture"))
        let outcome = StorageOverviewService().measureTree(path: fixture.path)
        let original = SecureCommandRunner().run(URL(fileURLWithPath: "/usr/bin/du"), arguments: ["-x", "-k", "-d", "1", fixture.path])
        let baseline = StorageOverviewService.parse(original, path: fixture.path)
        XCTAssertEqual(outcome.measurement.totalBytes, baseline.totalBytes)
        XCTAssertEqual(outcome.measurement.folders, baseline.folders)
        XCTAssertEqual(outcome.children.count, 1)
        XCTAssertEqual(outcome.children.first?.folders.first?.path, nested.path)
        XCTAssertFalse(outcome.children.first?.limitedAccess ?? true)
    }

    func testHistoryThrottlesSamplesRetainsCleanupAndRejectsInvalidValues() throws {
        var history = DiskSpaceHistory()
        let start = Date()
        XCTAssertTrue(history.record(free: 10, capacity: 100, date: start))
        XCTAssertFalse(history.record(free: 9, capacity: 100, date: start.addingTimeInterval(2)))
        XCTAssertTrue(history.record(free: 12, capacity: 100, date: start.addingTimeInterval(3), cleanup: true))
        XCTAssertFalse(history.record(free: 101, capacity: 100, date: start.addingTimeInterval(4)))
        XCTAssertEqual(history.samples.count, 2)
        XCTAssertTrue(history.samples.last!.cleanup)
        let decoded = try JSONDecoder().decode([DiskSpaceSample].self, from: JSONEncoder().encode(history.samples))
        XCTAssertEqual(decoded, history.samples)
        XCTAssertTrue(history.record(free: 20, capacity: 100, date: start.addingTimeInterval(31 * 86_400)))
        XCTAssertEqual(history.samples.count, 1)
    }
}
