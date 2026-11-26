import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Sift

final class UnreadableCacheTests: XCTestCase {
    private var root: URL!
    private let files = FileManager.default
    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("Sift-unreadable-cache-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try files.removeItem(at: root) }

    private func updater(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent("Library/Caches/\(name)-updater")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let canary = directory.appendingPathComponent("pending.zip")
        try Data(repeating: 1, count: 4096).write(to: canary)
        let old = Date().addingTimeInterval(-3 * 86_400)
        for url in [directory, canary] { try files.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        return directory
    }

    func testMixedReadableAndUntraversableUpdaterFoldersStayUseful() throws {
        let readable = try updater("readable")
        let unreadable = try updater("unreadable")
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
        // Match Slack's observed situation: directory names can be listed but
        // child metadata cannot be traversed. Only our fixture is changed.
        try files.setAttributes([.posixPermissions: 0o444], ofItemAtPath: unreadable.path)
        let service = RegenerableCacheService(home: root, runningAppNames: { [] })
        let inspected = try XCTUnwrap(service.inspect(id: "app-updaters"))
        XCTAssertGreaterThan(inspected.bytes, 0)
        XCTAssertEqual(inspected.bytes, DirectoryMeasurement.measure(readable)?.bytes)
        XCTAssertNil(inspected.measuredBytes, "Readable subtotal is not a complete measurement")
        XCTAssertEqual(inspected.skippedLocations.map(\.path), [unreadable.standardizedFileURL.path])
        XCTAssertTrue(inspected.skippedLocations[0].reason.contains("Permission denied"))
        XCTAssertTrue(CleanupInventory(worktreeBytes: 0, caches: [inspected], docker: .checking).hasUnmeasuredSources)
        try service.clean(id: "app-updaters")
        XCTAssertFalse(files.fileExists(atPath: readable.path))
        let after = try XCTUnwrap(service.inspectAfterCleanup(id: "app-updaters"))
        XCTAssertNil(after.measuredBytes)
        XCTAssertEqual(after.skippedLocations.map(\.path), inspected.skippedLocations.map(\.path))
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
        XCTAssertTrue(files.fileExists(atPath: unreadable.appendingPathComponent("pending.zip").path))
    }

    func testUnreadableDescendantPreservesEntireMatchedFolder() throws {
        let directory = try updater("nested")
        let locked = directory.appendingPathComponent("locked")
        try files.createDirectory(at: locked, withIntermediateDirectories: true)
        let canary = locked.appendingPathComponent("keep")
        try Data([1]).write(to: canary)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let service = RegenerableCacheService(home: root, runningAppNames: { [] })
        let inspected = try XCTUnwrap(service.inspect(id: "app-updaters"))
        XCTAssertEqual(inspected.skippedLocations.first?.path, directory.standardizedFileURL.path)
        XCTAssertNil(inspected.measuredBytes)
        try service.clean(id: "app-updaters")
        XCTAssertTrue(files.fileExists(atPath: directory.appendingPathComponent("pending.zip").path))
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        XCTAssertTrue(files.fileExists(atPath: canary.path))
    }

    func testWildcardBasesContinueAfterAnUnreadablePartition() throws {
        let base = root.appendingPathComponent("Library/Application Support/App/Partitions")
        let good = base.appendingPathComponent("good/Cache")
        let bad = base.appendingPathComponent("bad")
        for url in [good, bad.appendingPathComponent("Cache")] { try files.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data([1]).write(to: good.appendingPathComponent("remove"))
        let keep = bad.appendingPathComponent("Cache/keep")
        try Data([1]).write(to: keep)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bad.path) }
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bad.path)
        let definition = RegenerableCacheDefinition(id: "fixture", name: "Fixture", targets: [.contents("Library/Application Support/App/Partitions/*/Cache")], appNames: [], detail: "")
        let service = RegenerableCacheService(home: root, runningAppNames: { [] })
        let inspected = try XCTUnwrap(service.inspect(definition))
        XCTAssertGreaterThan(inspected.bytes, 0)
        XCTAssertEqual(inspected.skippedLocations.count, 1)
        try service.clean(definition)
        XCTAssertFalse(files.fileExists(atPath: good.appendingPathComponent("remove").path))
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bad.path)
        XCTAssertTrue(files.fileExists(atPath: keep.path))
    }

    func testWarningsClearAfterAccessReturns() throws {
        let directory = try updater("restore")
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let service = RegenerableCacheService(home: root, runningAppNames: { [] })
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        XCTAssertTrue(service.inspect(id: "app-updaters")?.hasPartialMeasurement == true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let restored = try XCTUnwrap(service.inspect(id: "app-updaters"))
        XCTAssertTrue(restored.skippedLocations.isEmpty)
        XCTAssertNotNil(restored.measuredBytes)
    }

    @MainActor func testPartialCleanupDoesNotClaimCompleteSizeReduction() async throws {
        let _ = try updater("good")
        let bad = try updater("bad")
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bad.path) }
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bad.path)
        let service = RegenerableCacheService(home: root, runningAppNames: { [] })
        let cache = try XCTUnwrap(service.inspect(id: "app-updaters"))
        let model = AppModel(cleanup: .init(cleanCache: { try service.clean(id: $0) }, inspectCache: { service.inspectAfterCleanup(id: $0) }, pruneDocker: { "" }, inspectDocker: { .checking }))
        model.globalCaches = [cache]
        model.cleanGlobalCache(cache)
        for _ in 0..<200 {
            if !model.isCleaning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isCleaning)
        XCTAssertNil(model.globalCaches.first?.measuredBytes)
        XCTAssertEqual(model.globalCaches.first?.skippedLocations.count, 1)
        XCTAssertFalse(model.lastMessage?.contains("stored size decreased") == true)
    }

    @MainActor func testSkippedRowsRenderInExpandedDashboard() {
        let caches = [GlobalCache(id: "app-updaters", name: "App update downloads", detail: "Fixture", symbolName: "arrow.down.app", state: .available(bytes: 4096, path: "/fixture/readable"), skippedLocations: [.init(path: "/fixture/unreadable", reason: "Permission denied")])]
        let view = CleanupDashboardView(inventory: .init(worktreeBytes: 0, caches: caches, docker: .checking), observation: nil, cleaningIDs: [], cleaningDocker: false, eligibleCount: 1, onClean: { _ in XCTFail() }, onDocker: { XCTFail() }, onCleanEligible: { XCTFail() }, onStopUV: { _ in XCTFail() }, expandedCategories: [.apps], expandedRows: ["app-updaters"])
        let host = NSHostingView(rootView: view.frame(width: 424))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 424, accuracy: 1)
        XCTAssertGreaterThan(host.fittingSize.height, 200)
    }
}
