import Foundation
import XCTest
@testable import DevSweep

final class CleanupSafetyTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevSweepTests-\(UUID().uuidString)", isDirectory: true)
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
        try "keep".write(to: workspaceURL.appendingPathComponent("source.swift"), atomically: true, encoding: .utf8)

        let candidate = CleanupCandidate(url: candidateURL, kind: CleanupKind.byDirectoryName[".next"]!, allocatedBytes: 4)
        let workspace = testWorkspace(url: workspaceURL, candidates: [candidate])
        let result = CleanupService(trashService: TestTrashService(destination: trashURL)).remove([candidate], from: [workspace])

        XCTAssertEqual(result.trashed, [candidate])
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.appendingPathComponent(".next").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent("source.swift").path))
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

    func testDockerConnectionErrorsArePresentedWithoutSocketDetails() {
        let rawError = "failed to connect to the docker API at unix:///Users/person/.orbstack/run/docker.sock; check if the daemon is running"

        let message = DockerService.userFacingError(rawError)

        XCTAssertEqual(message, "Docker Desktop or OrbStack isn’t running")
        XCTAssertFalse(message.contains("/Users/"))
        XCTAssertFalse(message.contains("docker.sock"))
    }

    func testDockerPermissionErrorsHaveAnActionableMessage() {
        XCTAssertEqual(
            DockerService.userFacingError("permission denied while trying to connect"),
            "Docker is running, but DevSweep cannot access it"
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
}

private struct TestTrashService: TrashServing {
    let destination: URL

    func trashItem(at url: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
    }
}
