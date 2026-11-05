import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import Sift

final class StorageExplorerTests: XCTestCase {
    private func snapshot(_ folders: [StorageFolder] = [], complete: Bool = true, limited: Bool = false) -> StorageMeasurement {
        StorageMeasurement(path: "/example", folders: folders, totalBytes: complete ? 1000 : nil,
            date: Date(), limitedAccess: limited, timedOut: false)
    }

    func testBreadcrumbsPreservePhysicalAndHomeAliasPathsWithoutScanning() {
        let root = StorageOverviewService.rootPath
        XCTAssertEqual(StorageExplorerResults.breadcrumbs(root), [.init(path: root, name: "Data")])
        let aliased = StorageExplorerResults.breadcrumbs("/Users/test/Library")
        XCTAssertEqual(aliased.map(\.name), ["Data", "Users", "test", "Library"])
        XCTAssertEqual(aliased.map(\.path), [root, "/Users", "/Users/test", "/Users/test/Library"])
        let physical = StorageExplorerResults.breadcrumbs(root + "/Users/test/Library")
        XCTAssertEqual(physical.last?.path, root + "/Users/test/Library")
        XCTAssertEqual(physical[1].path, root + "/Users")
    }

    func testFilteringIsCaseInsensitiveMultiwordAndLimitedToMeasuredRows() {
        let measurement = snapshot([.init(path: "/example/Project data", bytes: 20), .init(path: "/example/cache", bytes: 10)])
        XCTAssertEqual(StorageExplorerResults.folders(measurement, query: "PROJECT example", sort: .size, baseline: nil).map(\.bytes), [20])
        XCTAssertTrue(StorageExplorerResults.folders(measurement, query: "not measured", sort: .size, baseline: nil).isEmpty)
        XCTAssertEqual(StorageExplorerResults.folders(measurement, query: "  ", sort: .name, baseline: nil).first?.name, "cache")
    }

    func testGrowthSortRequiresCompleteComparableSnapshotsAndIncludesNewFolders() {
        let old = snapshot([.init(path: "/example/big", bytes: 800), .init(path: "/example/growing", bytes: 10)])
        let folders: [StorageFolder] = [.init(path: "/example/big", bytes: 900), .init(path: "/example/growing", bytes: 300), .init(path: "/example/new", bytes: 400)]
        let current = snapshot(folders)
        XCTAssertEqual(StorageExplorerResults.folders(current, query: "", sort: .growth, baseline: old).map(\.name), ["new", "growing", "big"])
        XCTAssertEqual(StorageExplorerResults.folders(snapshot(folders, complete: false), query: "", sort: .growth, baseline: old).first?.name, "big")
        XCTAssertEqual(StorageExplorerResults.folders(snapshot(folders, limited: true), query: "", sort: .growth, baseline: old).first?.name, "big")
        var different = old; different.accountingScope = "/other"
        XCTAssertEqual(StorageExplorerResults.folders(current, query: "", sort: .growth, baseline: different).first?.name, "big")
    }

    func testRecognizedCacheHandoffUsesExactBoundariesAndDataAliases() {
        let cache = GlobalCache(id: "uv", name: "uv cache", detail: "", symbolName: "bolt", state: .available(bytes: 500, path: "/Users/test/.cache/uv"))
        let matched = StoragePathContext.classify(StorageOverviewService.rootPath + "/Users/test/.cache/uv/data/file", caches: [cache], workspaces: [])
        XCTAssertEqual(matched.label, "Known cache")
        XCTAssertEqual(matched.target?.kind, .cache("uv"))
        XCTAssertEqual(matched.target?.path, "/Users/test/.cache/uv", "Review is for the entire supported cache, not an arbitrary nested file")
        XCTAssertNil(StoragePathContext.classify("/Users/test/.cache/uv-keep", caches: [cache], workspaces: []).target)
        XCTAssertNil(StoragePathContext.classify("/Users/test/.cache", caches: [cache], workspaces: []).target)
        XCTAssertNil(StoragePathContext.classify("/Users/test/.cache/uv/../../Documents", caches: [cache], workspaces: []).target)
    }

    func testGeneratedDataOnlyLinksKnownCandidatesAndNeverSourceFiles() {
        let root = URL(fileURLWithPath: "/projects/repo")
        let kind = CleanupKind.supported.first { $0.directoryName == "node_modules" }!
        let candidate = CleanupCandidate(url: root.appendingPathComponent("node_modules"), kind: kind, allocatedBytes: 100)
        let workspace = Workspace(url: root, name: "repo", branch: "main", repositoryID: "repo", repositoryName: "repo", candidates: [candidate])
        let generated = StoragePathContext.classify("/projects/repo/node_modules/package/index.js", caches: [], workspaces: [workspace])
        XCTAssertEqual(generated.target?.kind, .workspace(workspace.id))
        XCTAssertEqual(generated.label, "Generated data")
        XCTAssertNil(StoragePathContext.classify("/projects/repo/src/index.js", caches: [], workspaces: [workspace]).target)
        XCTAssertNil(StoragePathContext.classify("/projects/unknown/node_modules", caches: [], workspaces: [workspace]).target)
        let personal = StoragePathContext.classify("/Users/test/Downloads/archive.zip", caches: [], workspaces: [], home: "/Users/test")
        XCTAssertEqual(personal.label, "Personal data")
        XCTAssertNil(personal.target)
    }

    func testFileListUsesAllocationRatherThanLogicalSizeAndNeverAggregatesFolders() {
        var measurement = snapshot([.init(path: "/example/folder", bytes: 1000)])
        measurement.largeFiles = [
            .init(path: "/example/sparse.img", bytes: 0, logicalBytes: 10_000_000_000, shared: false),
            .init(path: "/example/folder/shared.zip", bytes: 800, logicalBytes: 1000, shared: true)
        ]
        XCTAssertEqual(StorageExplorerResults.files(measurement, query: "", sort: .size).first?.name, "shared.zip")
        XCTAssertEqual(StorageExplorerResults.files(measurement, query: "folder zip", sort: .name).count, 1)
        XCTAssertEqual(measurement.totalBytes, 1000, "File samples overlap folder totals and must not be added to them")
        XCTAssertEqual(StorageExplorerResults.fraction(bytes: 20, maximum: 10), 1)
        XCTAssertEqual(StorageExplorerResults.fraction(bytes: -1, maximum: 10), 0)
        XCTAssertEqual(StorageExplorerResults.fraction(bytes: 10, maximum: 0), 0)
    }

    func testLargeFileHistoryIsBackwardsCompatibleAndSurvivesPartialResults() throws {
        let legacy = snapshot()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "largeFiles"); json.removeValue(forKey: "fileCount")
        XCTAssertNil(try JSONDecoder().decode(StorageMeasurement.self, from: JSONSerialization.data(withJSONObject: json)).largeFiles)
        var current = legacy
        current.largeFiles = [.init(path: "/example/file", bytes: 500, logicalBytes: 600, shared: true)]
        current.fileCount = 20
        let progress = StorageScanProgress(path: "/example", startedAt: Date(), completedDirectories: 1, currentPath: nil, folders: [], children: [], totalBytes: nil,
            largeFiles: current.largeFiles, fileCount: current.fileCount)
        let partial = progress.displaying(over: legacy)
        XCTAssertNil(partial.totalBytes)
        XCTAssertEqual(partial.largeFiles, current.largeFiles)
        XCTAssertEqual(partial.fileCount, 20)
        let decoded = try JSONDecoder().decode(StorageMeasurement.self, from: JSONEncoder().encode(partial))
        XCTAssertEqual(decoded.largeFiles, current.largeFiles)
    }

    func testNativeFileDiscoveryIsBoundedRecursiveAndDoesNotFollowLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-file-discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        for index in 0..<120 {
            try Data(repeating: UInt8(index), count: 4096).write(to: root.appendingPathComponent(String(format: "small-%03d", index)))
        }
        let largest = root.appendingPathComponent("nested/largest.dmg")
        try Data(repeating: 99, count: 1_048_576).write(to: largest)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: largest)
        let first = try NativeStorageScanner(workers: 1).measure(path: root.path).measurement
        let second = try NativeStorageScanner(workers: 4).measure(path: root.path).measurement
        XCTAssertEqual(first.largeFiles?.count, StorageExplorerResults.fileLimit)
        XCTAssertEqual(first.fileCount, 121)
        XCTAssertEqual(first.largeFiles?.first?.path, largest.path)
        XCTAssertEqual(first.largeFiles, second.largeFiles)
        XCTAssertFalse(first.largeFiles?.contains { $0.path == root.appendingPathComponent("link").path } ?? true)
        XCTAssertEqual(first.largeFiles?.first?.logicalBytes, 1_048_576)
        var metadata = stat(); XCTAssertEqual(lstat(largest.path, &metadata), 0)
        XCTAssertEqual(first.largeFiles?.first?.bytes, Int64(metadata.st_blocks) * 512)
    }

    func testBoundedHeapMatchesFullSortWithTiesAndSkipsRejectedPathAllocation() {
        var sample = StorageFileSample()
        var all: [StorageFile] = []
        for index in (0..<1000).reversed() {
            let file = StorageFile(path: String(format: "/example/%04d", index), bytes: Int64(index % 17), logicalBytes: 100, shared: false)
            all.append(file)
            sample.consider(bytes: file.bytes, logicalBytes: file.logicalBytes, shared: file.shared, path: file.path)
        }
        let expected = all.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
        XCTAssertEqual(sample.sorted, Array(expected.prefix(StorageFile.sampleLimit)))
        func rejectedPath() -> String { XCTFail("Clearly smaller files should not allocate a path"); return "/rejected" }
        sample.consider(bytes: 0, logicalBytes: 0, shared: false, path: rejectedPath())
        XCTAssertEqual(sample.sorted, Array(expected.prefix(StorageFile.sampleLimit)))
    }

    @MainActor func testFileDiscoveryAndFullRescanCannotBeSatisfiedByFolderOnlyParentResult() async throws {
        for fullRescan in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-required-index-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let started = expectation(description: "Parent scan started")
            let discovered = expectation(description: "Child scan actually ran")
            let gate = DispatchSemaphore(value: 0)
            let model = StorageOverviewModel(store: StorageHistoryStore(url: directory.appendingPathComponent("history.json")), measure: { path, _, _ in
                if path == "/root" {
                    started.fulfill()
                    _ = gate.wait(timeout: .now() + 2)
                    let child = StorageMeasurement(path: "/root/child", folders: [], totalBytes: 100, date: Date(), limitedAccess: false, timedOut: false)
                    return (StorageMeasurement(path: path, folders: [.init(path: child.path, bytes: 100)], totalBytes: 100, date: Date(), limitedAccess: false, timedOut: false), [child])
                }
                discovered.fulfill()
                return (StorageMeasurement(path: path, folders: [], totalBytes: 100, date: Date(), limitedAccess: false, timedOut: false,
                    largeFiles: [.init(path: path + "/file", bytes: 100, logicalBytes: 100, shared: false)], fileCount: 1), [])
            })
            model.scan("/root")
            await fulfillment(of: [started], timeout: 2)
            // Upgrade an already queued directory-only request as well.
            model.scan("/root/child")
            if fullRescan { model.scan("/root/child", fullRescan: true) }
            else { model.location = "/root/child"; model.scanCurrentFolder() }
            gate.signal()
            await fulfillment(of: [discovered], timeout: 2)
            for _ in 0..<100 where !model.scanningPaths.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(model.measurements["/root/child"]?.fileCount, 1)
        }
    }

    @MainActor func testCancelledFileSamplePersistsWithoutReplacingSuccessfulTotal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-partial-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StorageHistoryStore(url: directory.appendingPathComponent("history.json"))
        let old = snapshot([.init(path: "/example/old", bytes: 800)])
        store.save([old.path: old])
        let file = StorageFile(path: "/example/file", bytes: 100, logicalBytes: 150, shared: true)
        let model = StorageOverviewModel(store: store, measure: { path, _, _ in
            (StorageMeasurement(path: path, folders: [], totalBytes: nil, date: Date(), limitedAccess: true, timedOut: false, cancelled: true,
                largeFiles: [file], fileCount: 10), [])
        })
        model.location = old.path
        model.scanCurrentFolder()
        for _ in 0..<100 where !model.scanningPaths.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let restarted = StorageOverviewModel(store: store)
        XCTAssertEqual(restarted.measurements[old.path]?.totalBytes, 1000)
        XCTAssertNil(restarted.partialMeasurements[old.path]?.totalBytes)
        XCTAssertEqual(restarted.partialMeasurements[old.path]?.largeFiles, [file])
        XCTAssertEqual(restarted.partialMeasurements[old.path]?.fileCount, 10)
        XCTAssertEqual(restarted.partialMeasurements[old.path]?.cancelled, true)
    }

    @MainActor func testNavigationDoesNotScanAndRefreshUsesCurrentFolder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-location-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scanned = expectation(description: "Only current folder scanned")
        let model = StorageOverviewModel(store: StorageHistoryStore(url: directory.appendingPathComponent("history.json")), measure: { path, _, _ in
            XCTAssertEqual(path, "/Users/test/Library")
            scanned.fulfill()
            return (StorageMeasurement(path: path, folders: [], totalBytes: 0, date: Date(), limitedAccess: false, timedOut: false), [])
        })
        model.location = "/Users/test/Library"
        XCTAssertTrue(model.scanningPaths.isEmpty)
        XCTAssertTrue(model.queuedPaths.isEmpty)
        model.scanCurrentFolder()
        await fulfillment(of: [scanned], timeout: 2)
        for _ in 0..<100 where !model.scanningPaths.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(model.measurements[model.location])
        XCTAssertNil(model.measurements[StorageOverviewService.rootPath])
    }

    @MainActor func testExplorerLayoutsInBothModesAndAppearancesWithoutScanningOrCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sift-explorer-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StorageHistoryStore(url: directory.appendingPathComponent("history.json"))
        var measurement = snapshot([.init(path: "/example/Library", bytes: 800), .init(path: "/example/denied", bytes: 0, limitedAccess: true)], limited: true)
        measurement.largeFiles = [.init(path: "/example/nested/archive-with-a-very-long-name.dmg", bytes: 700, logicalBytes: 1000, shared: true)]
        measurement.fileCount = 1
        store.save([measurement.path: measurement])
        let fixture = measurement
        let overview = StorageOverviewModel(store: store, measure: { _, _, _ in XCTFail("Rendering or navigating must not scan"); return (fixture, []) })
        overview.location = measurement.path
        let app = AppModel()
        app.workspaces = []; app.globalCaches = []; app.selectedCandidateIDs = []
        for files in [false, true] {
            for scheme in [ColorScheme.dark, .light] {
                let content = ScrollView {
                    StorageExplorerView(overview: overview, onReviewCleanup: { _ in XCTFail("Rendering must not start cleanup review") }, showingFiles: files)
                        .environmentObject(app).padding(18)
                }.frame(width: 460, height: 660).preferredColorScheme(scheme)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: 460, height: 660)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.frame.width, 460)
                XCTAssertTrue(overview.scanningPaths.isEmpty)
                XCTAssertTrue(app.selectedCandidateIDs.isEmpty)
                XCTAssertFalse(app.isCleaning)
            }
        }
    }
}
