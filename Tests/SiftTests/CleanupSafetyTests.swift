import Foundation
import XCTest
@testable import Sift

final class CleanupSafetyTests: XCTestCase {
    func testUVLockParserAcceptsOnlyUVProcessesAndDeduplicatesPIDs() {
        let output = """
        p1284
        cuv
        f9
        p37126
        cuv
        f9
        p37126
        cuv
        p999
        cpython
        """

        XCTAssertEqual(
            UVLockProcessService.parse(output),
            [UVLockProcess(pid: 1284, command: "uv"), UVLockProcess(pid: 37126, command: "uv")]
        )
    }

    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot, FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testScannerFindsGeneratedDirectoriesAndBranch() throws {
        let workspace = temporaryRoot.appendingPathComponent("example", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/feature/sweep\n".write(to: workspace.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1024).write(to: workspace.appendingPathComponent("node_modules/pkg/data.bin"))
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("src"), withIntermediateDirectories: true)

        let results = WorkspaceScanner().scan(roots: [temporaryRoot])

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].branch, "feature/sweep")
        XCTAssertEqual(results[0].candidates.map(\.url.lastPathComponent), ["node_modules"])
        XCTAssertGreaterThan(results[0].reclaimableBytes, 0)
    }

    func testCleanerTrashesAllowListedDirectoryButPreservesWorkspace() throws {
        let workspaceURL = temporaryRoot.appendingPathComponent("project", isDirectory: true)
        let candidateURL = workspaceURL.appendingPathComponent(".next", isDirectory: true)
        let trashURL = temporaryRoot.appendingPathComponent("TestTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "keep".write(to: workspaceURL.appendingPathComponent("source.swift"), atomically: true, encoding: .utf8)

        let candidate = CleanupCandidate(url: candidateURL, kind: CleanupKind.byDirectoryName[".next"]!, allocatedBytes: 4)
        let workspace = testWorkspace(url: workspaceURL, candidates: [candidate])
        let result = CleanupService(trashService: TestTrashService(destination: trashURL)).remove([candidate], from: [workspace])

        XCTAssertEqual(result.trashed, [candidate])
        XCTAssertEqual(result.trashedURLs.map(\.standardizedFileURL.path), [trashURL.appendingPathComponent(".next").standardizedFileURL.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.appendingPathComponent(".next").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent("source.swift").path))
    }

    func testCleanerCanDeleteAllowListedDirectoryImmediatelyButPreservesWorkspace() throws {
        let workspaceURL = temporaryRoot.appendingPathComponent("permanent-project", isDirectory: true)
        let candidateURL = workspaceURL.appendingPathComponent("node_modules", isDirectory: true)
        let sourceURL = workspaceURL.appendingPathComponent("source.swift")
        try FileManager.default.createDirectory(at: workspaceURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let candidate = CleanupCandidate(
            url: candidateURL,
            kind: CleanupKind.byDirectoryName["node_modules"]!,
            allocatedBytes: 4
        )
        let workspace = Workspace(
            url: workspaceURL,
            name: "permanent-project",
            branch: "main",
            repositoryID: workspaceURL.appendingPathComponent(".git").path,
            repositoryName: "permanent-project",
            candidates: [candidate]
        )

        let result = CleanupService().remove([candidate], from: [workspace], mode: .deleteImmediately)

        XCTAssertEqual(result.trashed.count, 1)
        XCTAssertTrue(result.trashedURLs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent(".git").path))
    }

    func testCleanerRejectsWorkspaceRootEvenIfCandidateMetadataIsForged() throws {
        let workspaceURL = temporaryRoot.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let candidate = CleanupCandidate(url: workspaceURL, kind: CleanupKind.byDirectoryName["node_modules"]!, allocatedBytes: 0)
        let workspace = testWorkspace(url: workspaceURL, candidates: [candidate])

        XCTAssertThrowsError(try CleanupService().validate(candidate: candidate, in: workspace)) { error in
            XCTAssertEqual(error as? CleanupSafetyError, .workspaceItself)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
    }

    func testCleanerRejectsOutsideDirectory() throws {
        let workspaceURL = temporaryRoot.appendingPathComponent("project", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let candidate = CleanupCandidate(url: outside, kind: CleanupKind.byDirectoryName["node_modules"]!, allocatedBytes: 0)
        let workspace = testWorkspace(url: workspaceURL, candidates: [candidate])

        XCTAssertThrowsError(try CleanupService().validate(candidate: candidate, in: workspace)) { error in
            XCTAssertEqual(error as? CleanupSafetyError, .outsideWorkspace)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testCleanerRejectsCandidateReachedThroughSymlinkedAncestor() throws {
        let workspaceURL = temporaryRoot.appendingPathComponent("project", isDirectory: true)
        let outsideRoot = temporaryRoot.appendingPathComponent("external", isDirectory: true)
        let outsideCandidate = outsideRoot.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideCandidate, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: workspaceURL.appendingPathComponent("linked"),
            withDestinationURL: outsideRoot
        )
        let linkedCandidate = workspaceURL.appendingPathComponent("linked/node_modules", isDirectory: true)
        let candidate = CleanupCandidate(url: linkedCandidate, kind: CleanupKind.byDirectoryName["node_modules"]!, allocatedBytes: 0)
        let workspace = testWorkspace(url: workspaceURL, candidates: [candidate])

        XCTAssertThrowsError(try CleanupService().validate(candidate: candidate, in: workspace)) { error in
            XCTAssertEqual(error as? CleanupSafetyError, .outsideWorkspace)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideCandidate.path))
    }

    func testDockerSizeParser() {
        XCTAssertEqual(DockerService.parseHumanSize("21.07GB (99%)"), 21_070_000_000)
        XCTAssertEqual(DockerService.parseHumanSize("0B"), 0)
        XCTAssertEqual(DockerService.parseHumanSize("512MB (40%)"), 512_000_000)
    }

    func testDockerPruneOutputSumsImageAndBuildCacheReclaims() {
        let output = """
        Total reclaimed space: 1.5GB
        Total reclaimed space: 250MB
        """
        XCTAssertEqual(DockerService.reclaimedBytes(fromPruneOutput: output), 1_750_000_000)
    }

    func testPartialGlobalCachesDoNotClaimTheirWholeSizeIsReclaimable() {
        let partial = GlobalCache(
            id: "pnpm", name: "pnpm store", detail: "", symbolName: "shippingbox.fill",
            state: .available(bytes: 5_000_000_000, path: "/tmp/pnpm")
        )
        let full = GlobalCache(
            id: "bun", name: "Bun cache", detail: "", symbolName: "hare.fill",
            state: .available(bytes: 5_000_000_000, path: "/tmp/bun")
        )
        XCTAssertEqual(partial.reclaimableBytes, 0)
        XCTAssertEqual(full.reclaimableBytes, 5_000_000_000)
    }

    func testDockerSizeFormattingDoesNotRequirePercentage() {
        XCTAssertEqual(DockerService.parseHumanSize("0B (0%)"), 0)
        XCTAssertEqual(DockerService.parseHumanSize("15.89GB (67%)"), 15_890_000_000)
    }

    func testDockerUsageIncludesImagesAndReclaimableBuildCache() {
        let usage = DockerService.parseSystemDF("""
        Images|6|4.917GB|0B (0%)
        Containers|6|122.9kB|122.9kB (100%)
        Local Volumes|2|11.72kB|0B (0%)
        Build Cache|32|4.267GB|2.825GB
        """)
        XCTAssertEqual(usage.imageCount, 6)
        XCTAssertEqual(usage.imageBytes, 4_917_000_000)
        XCTAssertEqual(usage.reclaimableBytes, 2_825_000_000)
    }

    func testDockerOnlyAllowsLocalUnixSocketEndpoints() {
        XCTAssertTrue(DockerService.isAllowedEndpoint("unix:///Users/person/.orbstack/run/docker.sock"))
        XCTAssertFalse(DockerService.isAllowedEndpoint("ssh://builder@example.com"))
        XCTAssertFalse(DockerService.isAllowedEndpoint("tcp://192.0.2.1:2376"))
        XCTAssertFalse(DockerService.isAllowedEndpoint("unix:///tmp/docker.sock\nssh://example.com"))
    }

    func testUpdateVersionComparison() {
        XCTAssertEqual(UpdateService.compareVersions("0.1.12", "0.1.9"), .orderedDescending)
        XCTAssertEqual(UpdateService.compareVersions("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(UpdateService.compareVersions("0.9.9", "1.0.0"), .orderedAscending)
    }

    func testUpdateRepositoryAndURLsAreRestrictedToGitHub() throws {
        XCTAssertTrue(UpdateService.isValidRepository("owner/sift"))
        XCTAssertFalse(UpdateService.isValidRepository("owner/sift/extra"))
        XCTAssertFalse(UpdateService.isValidRepository("https://example.com/repo"))

        XCTAssertTrue(UpdateService.isAllowedDownloadURL(try XCTUnwrap(URL(string: "https://github.com/owner/sift/releases/download/v1/Sift-1.zip"))))
        XCTAssertFalse(UpdateService.isAllowedDownloadURL(try XCTUnwrap(URL(string: "https://example.com/Sift-1.zip"))))
        XCTAssertFalse(UpdateService.isAllowedDownloadURL(try XCTUnwrap(URL(string: "http://github.com/owner/sift/releases/download/v1/Sift-1.zip"))))
    }

    func testUpdaterAllowsOnlyTheDevSweepToSiftIdentityMigration() {
        XCTAssertTrue(UpdateService.isSupportedCurrentApplicationName("Sift.app"))
        XCTAssertTrue(UpdateService.isSupportedCurrentApplicationName("DevSweep.app"))
        XCTAssertFalse(UpdateService.isSupportedCurrentApplicationName("Other.app"))

        XCTAssertTrue(UpdateService.isAllowedBundleTransition(
            from: "com.dominikbura.sift",
            to: "com.dominikbura.sift"
        ))
        XCTAssertTrue(UpdateService.isAllowedBundleTransition(
            from: "com.dominikhait.devsweep",
            to: "com.dominikbura.sift"
        ))
        XCTAssertTrue(UpdateService.isAllowedBundleTransition(
            from: "com.dominikhait.sift",
            to: "com.dominikbura.sift"
        ))
        XCTAssertFalse(UpdateService.isAllowedBundleTransition(
            from: "com.dominikbura.sift",
            to: "com.example.untrusted"
        ))
        XCTAssertFalse(UpdateService.isAllowedBundleTransition(
            from: "com.dominikbura.sift",
            to: "com.dominikhait.devsweep"
        ))
    }

    func testDockerConnectionErrorsArePresentedWithoutSocketDetails() {
        let rawError = "failed to connect to the docker API at unix:///Users/person/.orbstack/run/docker.sock; check if the daemon is running"

        let message = DockerService.userFacingError(rawError)

        XCTAssertEqual(message, "Docker Engine is not running")
        XCTAssertFalse(message.contains("/Users/"))
        XCTAssertFalse(message.contains("docker.sock"))
    }

    func testDockerPermissionErrorsHaveAnActionableMessage() {
        XCTAssertEqual(
            DockerService.userFacingError("permission denied while trying to connect"),
            "Docker is running, but Sift cannot access it"
        )
    }

    func testLinkedWorktreesShareRepositoryIdentity() throws {
        let main = temporaryRoot.appendingPathComponent("example", isDirectory: true)
        let linked = temporaryRoot.appendingPathComponent("linked-example", isDirectory: true)
        let linkedGitDirectory = main.appendingPathComponent(".git/worktrees/linked-example", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedGitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: main.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/grouping\n".write(to: linkedGitDirectory.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: linkedGitDirectory.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(linkedGitDirectory.path)\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let scanner = WorkspaceScanner()
        let mainWorkspace = scanner.scanWorkspace(main)
        let linkedWorkspace = scanner.scanWorkspace(linked)

        XCTAssertEqual(mainWorkspace.repositoryID, linkedWorkspace.repositoryID)
        XCTAssertEqual(linkedWorkspace.repositoryName, "example")
        XCTAssertEqual(linkedWorkspace.branch, "feature/grouping")
    }

    func testKnownWorktreeRootUsesShallowDiscovery() throws {
        let knownRoot = temporaryRoot.appendingPathComponent(".codex/worktrees", isDirectory: true)
        let directWorkspace = knownRoot.appendingPathComponent("abcd/project", isDirectory: true)
        let tooDeepWorkspace = knownRoot.appendingPathComponent("one/two/three/project", isDirectory: true)
        try createGitWorkspace(at: directWorkspace)
        try createGitWorkspace(at: tooDeepWorkspace)

        let discovered = WorkspaceScanner().discoverWorkspaces(in: [knownRoot])

        XCTAssertTrue(discovered.contains(directWorkspace.standardizedFileURL))
        XCTAssertFalse(discovered.contains(tooDeepWorkspace.standardizedFileURL))
    }

    func testScanCacheRestoresExistingCandidatesAndDropsMissingOnes() throws {
        let root = temporaryRoot.appendingPathComponent("projects", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("project", isDirectory: true)
        let existingURL = workspaceURL.appendingPathComponent("node_modules", isDirectory: true)
        let missingURL = workspaceURL.appendingPathComponent(".next", isDirectory: true)
        try FileManager.default.createDirectory(at: existingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let existing = CleanupCandidate(url: existingURL, kind: CleanupKind.byDirectoryName["node_modules"]!, allocatedBytes: 123)
        let missing = CleanupCandidate(url: missingURL, kind: CleanupKind.byDirectoryName[".next"]!, allocatedBytes: 456)
        let workspace = testWorkspace(url: workspaceURL, candidates: [existing, missing])
        let cache = ScanCache(cacheURL: temporaryRoot.appendingPathComponent("cache/scan.json"))

        cache.save([workspace])
        let restored = cache.load(under: [root])

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].candidates, [existing])
    }

    func testWarmWorkspaceScanRemeasuresCandidateSize() throws {
        let workspaceURL = temporaryRoot.appendingPathComponent("warm-project", isDirectory: true)
        try createGitWorkspace(at: workspaceURL)
        let candidateURL = workspaceURL.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: candidateURL.appendingPathComponent("data.bin"))
        let scanner = WorkspaceScanner()

        let cold = scanner.scanWorkspace(workspaceURL, previous: nil)
        let warm = scanner.scanWorkspace(workspaceURL, previous: cold.workspace)

        XCTAssertEqual(cold.measuredSizeCount, 1)
        XCTAssertEqual(cold.reusedSizeCount, 0)
        XCTAssertEqual(warm.measuredSizeCount, 1)
        XCTAssertEqual(warm.reusedSizeCount, 0)
        XCTAssertEqual(warm.workspace.reclaimableBytes, cold.workspace.reclaimableBytes)
    }

    private func testWorkspace(url: URL, candidates: [CleanupCandidate]) -> Workspace {
        Workspace(
            url: url,
            name: url.lastPathComponent,
            branch: "main",
            repositoryID: url.appendingPathComponent(".git").path,
            repositoryName: url.lastPathComponent,
            candidates: candidates
        )
    }

    private func createGitWorkspace(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: url.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    }
}

private struct TestTrashService: TrashServing {
    let destination: URL

    func trashItem(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = destination.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: result)
        return result
    }
}
