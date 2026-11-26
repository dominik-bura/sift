import Foundation
import XCTest
@testable import Sift

final class CacheSafetyRegressionTests: XCTestCase {
    private var root: URL!
    private let files = FileManager.default
    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("Sift-cache-safety-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try files.removeItem(at: root) }

    private func updater() throws -> (URL, URL, RegenerableCacheService) {
        let directory = root.appendingPathComponent("Library/Caches/demo-updater")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pending.zip")
        try Data(repeating: 1, count: 4096).write(to: file)
        let old = Date().addingTimeInterval(-3 * 86_400)
        for url in [directory, file] { try files.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        return (directory, file, RegenerableCacheService(home: root, runningAppNames: { [] }))
    }

    func testReferencedGlobalVirtualStoresAndLinkMarkersAreNeverOffered() throws {
        let active = root.appendingPathComponent("store/v11")
        let referenced = root.appendingPathComponent("store/v10")
        let ordinary = root.appendingPathComponent("store/v3")
        let linkMarker = root.appendingPathComponent("store/v12")
        let package = referenced.appendingPathComponent("links/hash/node_modules/demo")
        let modules = root.appendingPathComponent("project/node_modules")
        for directory in [active, ordinary, linkMarker, package, modules] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("module.exports = 1".utf8).write(to: package.appendingPathComponent("index.js"))
        try files.createSymbolicLink(at: modules.appendingPathComponent("demo"), withDestinationURL: package)
        try files.createSymbolicLink(at: linkMarker.appendingPathComponent("links"), withDestinationURL: root.appendingPathComponent("missing"))
        let offered = try PnpmStoreLayout.otherStores(besides: active)
        XCTAssertEqual(offered.map(\.lastPathComponent), ["v3"])
        XCTAssertTrue(files.fileExists(atPath: modules.appendingPathComponent("demo/index.js").path))
        // Creating a links marker after the first inspection also excludes the
        // store in the cleaner's immediate pre-removal revalidation.
        try files.createDirectory(at: ordinary.appendingPathComponent("links"), withIntermediateDirectories: true)
        XCTAssertTrue(try PnpmStoreLayout.otherStores(besides: active).isEmpty)
    }

    func testWildcardPermissionErrorsAreExplicitlySkippedDuringInspectionAndCleanup() throws {
        let (directory, canary, service) = try updater()
        let parent = directory.deletingLastPathComponent()
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        let definition = try XCTUnwrap(RegenerableCacheService.definition(id: "app-updaters"))
        XCTAssertTrue(service.hasMatches(definition), "Keep a placeholder for the failed inspection")
        XCTAssertTrue(service.inspect(id: definition.id)?.hasPartialMeasurement == true)
        XCTAssertEqual(service.inspect(id: definition.id)?.skippedLocations.first?.path, parent.standardizedFileURL.path)
        XCTAssertNil(service.inspectAfterCleanup(id: definition.id)?.measuredBytes, "Skipped is not empty")
        XCTAssertNoThrow(try service.clean(id: definition.id))
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        XCTAssertTrue(files.fileExists(atPath: canary.path))
    }

    func testPnpmEnumerationPermissionFailurePropagates() throws {
        let store = root.appendingPathComponent("store")
        let active = store.appendingPathComponent("v11")
        try files.createDirectory(at: active, withIntermediateDirectories: true)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)
        XCTAssertThrowsError(try PnpmStoreLayout.otherStores(besides: active))
    }

    func testOnlyVerifiedAbsenceProducesAnEmptyPostCleanupMeasurement() throws {
        let (_, _, service) = try updater()
        try service.clean(id: "app-updaters")
        XCTAssertNil(service.inspect(id: "app-updaters"))
        XCTAssertEqual(service.inspectAfterCleanup(id: "app-updaters")?.measuredBytes, 0)
        XCTAssertTrue(try PnpmStoreLayout.otherStores(besides: root.appendingPathComponent("missing/v11")).isEmpty)
    }

    func testLiteralSymlinkCannotBeEnumeratedThroughWildcard() throws {
        let outside = root.appendingPathComponent("outside/demo-updater")
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: outside.deletingLastPathComponent())
        let service = RegenerableCacheService(home: root, runningAppNames: { [] })
        let definition = RegenerableCacheDefinition(id: "fixture", name: "Fixture", targets: [.item("Linked/*-updater")], appNames: [], detail: "")
        XCTAssertThrowsError(try service.matches(definition.targets[0]))
        XCTAssertThrowsError(try service.clean(definition))
        XCTAssertTrue(files.fileExists(atPath: outside.path))
    }

    @MainActor private func waitForCleanup(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if !model.isCleaning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Cleanup did not finish")
    }

    @MainActor func testRealServiceKeepsFreshUpdatesWithoutClaimingRemovedBytes() async throws {
        let (_, canary, service) = try updater()
        let cache = try XCTUnwrap(service.inspect(id: "app-updaters"))
        try files.setAttributes([.modificationDate: Date()], ofItemAtPath: canary.path)
        let model = AppModel(cleanup: .init(cleanCache: { try service.clean(id: $0) },
            inspectCache: { service.inspectAfterCleanup(id: $0) }, pruneDocker: { "" }, inspectDocker: { .checking }))
        model.globalCaches = [cache]
        model.cleanGlobalCache(cache)
        try await waitForCleanup(model)
        XCTAssertTrue(files.fileExists(atPath: canary.path))
        XCTAssertNil(model.globalCaches.first?.measuredBytes)
        XCTAssertFalse(model.lastMessage?.contains("stored size decreased") == true)
    }

    @MainActor func testRealServiceDoesNotReportPermissionFailureAsSuccessfulEmptyCleanup() async throws {
        let (directory, canary, service) = try updater()
        let cache = try XCTUnwrap(service.inspect(id: "app-updaters"))
        let parent = directory.deletingLastPathComponent()
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let model = AppModel(cleanup: .init(cleanCache: { try service.clean(id: $0) },
            inspectCache: { service.inspectAfterCleanup(id: $0) }, pruneDocker: { "" }, inspectDocker: { .checking }))
        model.globalCaches = [cache]
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        model.cleanGlobalCache(cache)
        try await waitForCleanup(model)
        XCTAssertNil(model.cleanupErrors["cache:app-updaters"])
        XCTAssertTrue(model.globalCaches.first?.hasPartialMeasurement == true)
        XCTAssertNil(model.globalCaches.first?.measuredBytes)
        XCTAssertFalse(model.lastMessage?.contains("stored size decreased") == true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        XCTAssertTrue(files.fileExists(atPath: canary.path))
    }

    @MainActor func testUnknownInspectionNeverMeansZeroBytes() async throws {
        let model = AppModel(cleanup: .init(cleanCache: { _ in }, inspectCache: { _ in nil },
            pruneDocker: { "" }, inspectDocker: { .checking }))
        let cache = GlobalCache(id: "pnpm-other-stores", name: "Other pnpm stores", detail: "Fixture", symbolName: "shippingbox",
                                state: .available(bytes: 4096, path: root.path))
        model.globalCaches = [cache]
        model.cleanGlobalCache(cache)
        try await waitForCleanup(model)
        XCTAssertNil(model.globalCaches.first?.measuredBytes)
        XCTAssertFalse(model.lastMessage?.contains("stored size decreased") == true)
    }
}
