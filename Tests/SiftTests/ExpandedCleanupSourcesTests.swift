import Foundation
import XCTest
@testable import Sift

final class ExpandedCleanupSourcesTests: XCTestCase {
    private var home: URL!
    private var files: FileManager { .default }

    override func setUpWithError() throws {
        home = files.temporaryDirectory.appendingPathComponent("Sift-sources-test-\(UUID())", isDirectory: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? files.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relativePath: String, bytes: Int = 4096, modified: Date? = nil) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if let modified {
            // Set the file first, then its parent: writing the file updates the parent.
            try files.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            try files.setAttributes([.modificationDate: modified], ofItemAtPath: url.deletingLastPathComponent().path)
        }
        return url
    }

    private func exists(_ relativePath: String) -> Bool {
        files.fileExists(atPath: home.appendingPathComponent(relativePath).path)
    }

    private func service(running: Set<String> = [], now: Date = Date()) -> RegenerableCacheService {
        RegenerableCacheService(home: home, runningAppNames: { running }, now: { now })
    }

    // MARK: - Project folders

    func testProjectFoldersIncludeTerraformAndPnpmStoreButNotCoverageHTML() throws {
        XCTAssertNotNil(CleanupKind.byDirectoryName[".terraform"]?.note, "Terraform cleanup must explain its consequence")
        XCTAssertNotNil(CleanupKind.byDirectoryName[".pnpm-store"])
        XCTAssertNil(CleanupKind.byDirectoryName["htmlcov"])
        XCTAssertNil(CleanupKind.byDirectoryName[".wrangler"], "Local D1/KV state is not regenerable")

        let workspace = home.appendingPathComponent("infra", isDirectory: true)
        try files.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: workspace.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try write("infra/terraform/.terraform/providers/provider.bin")
        try write("infra/terraform/terraform.tfstate")
        try write("infra/.pnpm-store/v3/files/package.bin")
        try write("infra/htmlcov/index.html")

        let found = WorkspaceScanner().scan(roots: [home])
        XCTAssertEqual(Set(found.flatMap(\.candidates).map(\.url.lastPathComponent)), [".terraform", ".pnpm-store"])
    }

    // MARK: - File-based cache definitions

    func testDefinitionIdentifiersAreUniqueAndNeverTargetAppState() {
        let ids = RegenerableCacheService.definitions.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(Set(ids).isDisjoint(with: ["uv", "pnpm", "bun", "yarn", "npm", "go", "homebrew", "pulumi", "simulators", GlobalCacheService.otherPnpmStoresID]))
        let protected = ["WebStorage", "workspaceStorage", "globalStorage", "Service Worker", "IndexedDB", "Local Storage",
                         "Session Storage", "Cookies", "PersistentCache", "vm_bundles", "/User/", "plans"]
        for definition in RegenerableCacheService.definitions {
            for target in definition.targets {
                XCTAssertFalse(target.pattern.hasPrefix("/"), "\(definition.id) must stay relative to the home folder")
                XCTAssertFalse(target.pattern.contains(".."), "\(definition.id) must not traverse upwards")
                XCTAssertFalse(target.pattern.split(separator: "/").first?.contains("*") == true, "\(definition.id) must not start with a wildcard")
                for name in protected {
                    XCTAssertFalse(target.pattern.contains(name), "\(definition.id) targets protected data: \(target.pattern)")
                }
            }
        }
    }

    func testNewSourcesHaveExpectedCategoriesAndReviewRules() {
        func cache(_ id: String) -> GlobalCache {
            GlobalCache(id: id, name: id, detail: "", symbolName: "", state: .available(bytes: 1, path: "/fixture/\(id)"))
        }
        for id in ["npx-cache", "reflex-bun", "pip-cache", GlobalCacheService.otherPnpmStoresID] {
            XCTAssertEqual(CacheCategory.containing(cache(id)), .packages, id)
        }
        for id in ["vscode-cache", "cursor-cache", "slack-cache", "claude-cache", "helium-cache", "app-updaters"] {
            XCTAssertEqual(CacheCategory.containing(cache(id)), .apps, id)
        }
        for id in ["docker-scout", "simulator-dyld", "xcode-docs", "virtualenv-wheels", "node-gyp", "playwright-browsers", "azcopy-logs"] {
            XCTAssertEqual(CacheCategory.containing(cache(id)), .developerTools, id)
        }
        XCTAssertFalse(cache("playwright-browsers").includedInCleanAll)
        XCTAssertFalse(cache(GlobalCacheService.otherPnpmStoresID).includedInCleanAll)
        XCTAssertTrue(cache("node-gyp").includedInCleanAll)
        XCTAssertTrue(cache(GlobalCacheService.otherPnpmStoresID).disappearsWhenEmpty)
        XCTAssertTrue(cache("app-updaters").disappearsWhenEmpty)
        XCTAssertFalse(cache("slack-cache").disappearsWhenEmpty)
    }

    func testEditorCleanupKeepsSettingsExtensionStorageAndWorkspaceState() throws {
        let base = "Library/Application Support/Code"
        try write("\(base)/Cache/Cache_Data/entry")
        try write("\(base)/CachedData/build/script.code")
        try write("\(base)/CachedExtensionVSIXs/extension.vsix")
        try write("\(base)/Partitions/vscode-browser/Cache/entry")
        try write("\(base)/Partitions/vscode-browser/Local Storage/state")
        try write("\(base)/WebStorage/1/data")
        try write("\(base)/User/workspaceStorage/abc/state.vscdb")
        try write("\(base)/User/settings.json")

        let inspected = try XCTUnwrap(service().inspect(id: "vscode-cache"))
        XCTAssertGreaterThan(inspected.bytes, 0)
        XCTAssertNotNil(inspected.lastChanged)
        try service().clean(id: "vscode-cache")

        for removed in ["Cache/Cache_Data", "CachedData/build", "CachedExtensionVSIXs/extension.vsix", "Partitions/vscode-browser/Cache/entry"] {
            XCTAssertFalse(exists("\(base)/\(removed)"), removed)
        }
        XCTAssertTrue(exists("\(base)/Cache"), "The cache directory itself stays in place")
        for kept in ["Partitions/vscode-browser/Local Storage/state", "WebStorage/1/data", "User/workspaceStorage/abc/state.vscdb", "User/settings.json"] {
            XCTAssertTrue(exists("\(base)/\(kept)"), kept)
        }
        XCTAssertEqual(service().inspect(id: "vscode-cache")?.bytes, 0)
    }

    func testRunningAppMatchedByBundleIdentifierBlocksCleanupWithReadableName() throws {
        try write("Library/Application Support/Code/Cache/entry")
        XCTAssertThrowsError(try service(running: ["com.microsoft.VSCode"]).clean(id: "vscode-cache")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Quit Visual Studio Code"), error.localizedDescription)
        }
        XCTAssertTrue(exists("Library/Application Support/Code/Cache/entry"))
    }

    func testWildcardTargetsSkipSymbolicLinksAndLiteralLinksFailClosed() throws {
        let definition = RegenerableCacheDefinition(
            id: "fixture", name: "Fixture", targets: [.contents("Library/Application Support/App/Partitions/*/Cache")],
            appNames: [], detail: "")
        try write("Library/Application Support/App/Partitions/one/Cache/entry")
        try write("Library/Application Support/App/Partitions/two/Cache/entry")
        try write("Elsewhere/Cache/keep")
        try files.createSymbolicLink(at: home.appendingPathComponent("Library/Application Support/App/Partitions/linked"),
                                     withDestinationURL: home.appendingPathComponent("Elsewhere"))

        XCTAssertEqual(try service().matches(definition.targets[0]).map { $0.deletingLastPathComponent().lastPathComponent }, ["one", "two"])
        try service().clean(definition)
        XCTAssertFalse(exists("Library/Application Support/App/Partitions/one/Cache/entry"))
        XCTAssertFalse(exists("Library/Application Support/App/Partitions/two/Cache/entry"))
        XCTAssertTrue(exists("Elsewhere/Cache/keep"), "A linked partition is never followed")

        // A literal path component that is a link is not skipped silently: the source fails.
        let literal = RegenerableCacheDefinition(id: "literal", name: "Literal", targets: [.contents("Linked/Cache")], appNames: [], detail: "")
        try files.createSymbolicLink(at: home.appendingPathComponent("Linked"), withDestinationURL: home.appendingPathComponent("Elsewhere"))
        XCTAssertThrowsError(try service().clean(literal))
        if case .failed = service().inspect(literal)?.state {} else { XCTFail("A redirected cache must be reported as failed") }
        XCTAssertTrue(exists("Elsewhere/Cache/keep"))
    }

    func testUpdaterCleanupRemovesOldFoldersAndKeepsRecentOrUnrelatedOnes() throws {
        let now = Date()
        let old = now.addingTimeInterval(-3 * 86_400)
        try write("Library/Caches/notion-updater/pending/update.zip", bytes: 8192, modified: old)
        try files.setAttributes([.modificationDate: old], ofItemAtPath: home.appendingPathComponent("Library/Caches/notion-updater").path)
        try write("Library/Caches/com.example.app.ShipIt/update.1/App.zip", modified: old)
        try files.setAttributes([.modificationDate: old], ofItemAtPath: home.appendingPathComponent("Library/Caches/com.example.app.ShipIt").path)
        try write("Library/Caches/fresh-updater/pending/update.zip")
        try write("Library/Caches/com.example.app/keep")
        try write("Library/Application Support/Caches/cursor-updater/installer.dmg", modified: old)

        let service = service(now: now)
        let inspected = try XCTUnwrap(service.inspect(id: "app-updaters"))
        XCTAssertGreaterThan(inspected.bytes, 0)
        try service.clean(id: "app-updaters")

        XCTAssertFalse(exists("Library/Caches/notion-updater"))
        XCTAssertFalse(exists("Library/Caches/com.example.app.ShipIt"))
        XCTAssertFalse(exists("Library/Application Support/Caches/cursor-updater"))
        XCTAssertTrue(exists("Library/Caches/fresh-updater/pending/update.zip"), "A download from the last day may still be pending")
        XCTAssertTrue(exists("Library/Caches/com.example.app/keep"))
        XCTAssertNil(service.inspect(id: "app-updaters"), "Only the recent download is left, and it is not offered")
    }

    func testAzCopyCleanupRemovesOnlyOldLogFiles() throws {
        let now = Date()
        let old = now.addingTimeInterval(-10 * 86_400)
        try write(".azcopy/job-a.log", modified: old)
        try write(".azcopy/job-b.log")
        try write(".azcopy/plans/job-a.steV", modified: old)
        // Writing the fixtures touched the shared parent; that must not matter for per-file age.
        try files.setAttributes([.modificationDate: old], ofItemAtPath: home.appendingPathComponent(".azcopy/job-a.log").path)

        try service(now: now).clean(id: "azcopy-logs")
        XCTAssertFalse(exists(".azcopy/job-a.log"))
        XCTAssertTrue(exists(".azcopy/job-b.log"))
        XCTAssertTrue(exists(".azcopy/plans/job-a.steV"), "Transfer plans are needed to resume jobs")
    }

    // MARK: - Measurement

    func testMeasurementReportsNewestChangeAndIgnoresFutureDates() throws {
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        let newer = now.addingTimeInterval(-20 * 86_400)
        try write("cache/a/old.bin", modified: old)
        try write("cache/b/newer.bin", modified: newer)
        try write("cache/c/future.bin", modified: now.addingTimeInterval(400 * 86_400))
        try files.setAttributes([.modificationDate: old], ofItemAtPath: home.appendingPathComponent("cache/c").path)
        try files.setAttributes([.modificationDate: old], ofItemAtPath: home.appendingPathComponent("cache").path)

        let measurement = try XCTUnwrap(DirectoryMeasurement.measure(home.appendingPathComponent("cache"), now: now))
        XCTAssertGreaterThanOrEqual(measurement.bytes, 3 * 4096)
        XCTAssertEqual(try XCTUnwrap(measurement.newestChange).timeIntervalSince1970, newer.timeIntervalSince1970, accuracy: 2)
        XCTAssertEqual(DirectoryMeasurement.measure(home.appendingPathComponent("missing")), DirectoryMeasurement())

        // A file linked twice inside the tree is counted once, and a link is never followed.
        try write("outside/large.bin", bytes: 64 * 1024)
        let single = try XCTUnwrap(DirectoryMeasurement.measure(home.appendingPathComponent("cache"), now: now)).bytes
        try files.linkItem(at: home.appendingPathComponent("cache/a/old.bin"), to: home.appendingPathComponent("cache/b/hardlink.bin"))
        try files.createSymbolicLink(at: home.appendingPathComponent("cache/a/link"), withDestinationURL: home.appendingPathComponent("outside"))
        XCTAssertEqual(DirectoryMeasurement.measure(home.appendingPathComponent("cache"), now: now)?.bytes, single)
    }

    // MARK: - pnpm stores

    func testPnpmStoreLayoutReturnsOnlyOtherVersionDirectories() throws {
        try write("Library/pnpm/store/v10/files/a")
        try write("Library/pnpm/store/v3/files/b")
        try write("Library/pnpm/store/v11/files/c")
        try write("Library/pnpm/store/vNext/files/d")
        try write("Library/pnpm/store/notes.txt")
        try write("Elsewhere/files/e")
        let store = home.appendingPathComponent("Library/pnpm/store")
        try files.createSymbolicLink(at: store.appendingPathComponent("v12"), withDestinationURL: home.appendingPathComponent("Elsewhere"))

        let others = try PnpmStoreLayout.otherStores(besides: store.appendingPathComponent("v10"))
        XCTAssertEqual(others.map(\.lastPathComponent), ["v11", "v3"])
        XCTAssertTrue(try PnpmStoreLayout.otherStores(besides: store).isEmpty, "An unversioned store path has no siblings to offer")
        XCTAssertTrue(PnpmStoreLayout.isVersionDirectoryName("v3"))
        for name in ["v", "3", "v3a", "V3", "v-1", "version"] {
            XCTAssertFalse(PnpmStoreLayout.isVersionDirectoryName(name), name)
        }
    }

    // MARK: - Recently changed caches

    func testRecentlyChangedCachesAreSkippedByBulkCleanupButPruneOnlySourcesAreNot() {
        let now = Date()
        func cache(_ id: String, changedDaysAgo days: Double?) -> GlobalCache {
            GlobalCache(id: id, name: id, detail: "", symbolName: "", state: .available(bytes: 100, path: "/fixture/\(id)"),
                        lastChanged: days.map { now.addingTimeInterval(-$0 * 86_400) })
        }
        XCTAssertTrue(cache("uv", changedDaysAgo: 2).skippedByBulkCleanup(now: now))
        XCTAssertFalse(cache("uv", changedDaysAgo: 30).skippedByBulkCleanup(now: now))
        XCTAssertFalse(cache("uv", changedDaysAgo: nil).skippedByBulkCleanup(now: now), "An unknown age never hides a source")
        XCTAssertFalse(cache("homebrew", changedDaysAgo: 0).skippedByBulkCleanup(now: now), "Pruning keeps what is in use")
        XCTAssertFalse(cache("app-updaters", changedDaysAgo: 5).skippedByBulkCleanup(now: now), "Leftovers follow their own 24-hour rule")
        XCTAssertFalse(cache("azcopy-logs", changedDaysAgo: 5).skippedByBulkCleanup(now: now))
        XCTAssertEqual(cache("uv", changedDaysAgo: 3).lastChangedLabel(now: now), "Changed 3 days ago")
        XCTAssertNil(cache("uv", changedDaysAgo: nil).lastChangedLabel(now: now))
    }

    @MainActor func testBulkCleanupOffersOnlyCachesThatAreNotInRecentUse() {
        let model = AppModel(cleanup: .init(cleanCache: { _ in }, inspectCache: { _ in nil },
                                            pruneDocker: { "" }, inspectDocker: { .checking }))
        func cache(_ id: String, changedDaysAgo days: Double) -> GlobalCache {
            GlobalCache(id: id, name: id, detail: "", symbolName: "", state: .available(bytes: 100, path: "/fixture/\(id)"),
                        lastChanged: Date().addingTimeInterval(-days * 86_400))
        }
        model.globalCaches = [cache("uv", changedDaysAgo: 1), cache("bun", changedDaysAgo: 60), cache("homebrew", changedDaysAgo: 1),
                              cache("playwright-browsers", changedDaysAgo: 60)]
        model.dockerState = .checking
        XCTAssertEqual(model.cleanableGlobalCaches.map(\.id), ["bun", "homebrew"])
    }
}
