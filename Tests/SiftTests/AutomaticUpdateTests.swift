import AppKit
import XCTest
@testable import Sift

private actor AutomaticUpdateGate {
    var calls = 0
    private var continuation: CheckedContinuation<URL, Error>?
    func run() async throws -> URL {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(failing: Bool = false) {
        if failing { continuation?.resume(throwing: NSError(domain: "fixture", code: 1)) }
        else { continuation?.resume(returning: URL(fileURLWithPath: "/fixture/Sift.app")) }
        continuation = nil
    }
}

@MainActor private final class AutomaticUpdateFixture {
    let suite = "Sift-automatic-update-tests-\(UUID())"
    lazy var preferences = UserDefaults(suiteName: suite)!
    let download = AutomaticUpdateGate()
    let cleanup = AutomaticUpdateGate()
    final class State {
        var windowsOpen = false
        var installs = 0
        var failInstall = false
    }
    let state = State()
    let release = UpdateRelease(version: "99.0.0", downloadURL: URL(string: "https://example.com/Sift.zip")!,
                                checksumURL: nil, digest: nil, releasePageURL: URL(string: "https://example.com/release")!)
    lazy var model = AppModel(cleanup: .init(cleanCache: { [cleanup] _ in _ = try await cleanup.run() },
        inspectCache: { _ in nil }, pruneDocker: { "" }, inspectDocker: { .unavailable("Fixture") }),
        updates: .init(check: { [release] in release }, download: { [download] _ in try await download.run() }, install: { [state] _ in
            state.installs += 1
            if state.failInstall { throw NSError(domain: "fixture-install", code: 1) }
        }), updatePreferences: preferences, showsUpdateWindows: false, startsAutomaticUpdateChecks: false,
        startsAutomaticInstallationTimer: false, updateWindowsAreOpen: { [state] in state.windowsOpen })
    var cache: GlobalCache { .init(id: "fixture", name: "Fixture", detail: "", symbolName: "bolt", state: .available(bytes: 100, path: "/fixture/cache")) }
    func resetPreferences() { preferences.removePersistentDomain(forName: suite) }
    func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fixture did not reach the expected state")
        throw CancellationError()
    }
    func prepare() async throws {
        model.automaticallyInstallsUpdates = true
        await model.checkForUpdates()
        try await wait { await self.download.calls == 1 }
        await download.finish()
        try await wait { self.model.isUpdateReady }
    }
}

final class AutomaticUpdateTests: XCTestCase {
    @MainActor func testOptInIsOffByDefaultAndPersistsWithoutPromptingOrInstalling() async throws {
        let f = AutomaticUpdateFixture()
        defer { f.resetPreferences() }
        XCTAssertFalse(f.model.automaticallyInstallsUpdates)
        await f.model.checkForUpdates()
        let count = await f.download.calls
        XCTAssertEqual(count, 0)
        XCTAssertEqual(f.state.installs, 0)
        f.model.automaticallyInstallsUpdates = true
        XCTAssertTrue(f.preferences.bool(forKey: "automaticallyInstallsUpdates.v1"))
        try await f.wait { await f.download.calls == 1 }
        XCTAssertTrue(f.model.isPreparingUpdate)
        XCTAssertFalse(f.model.isUpdating)
        f.model.setUpdatePromptContext(active: true, allowsPrompt: true)
        XCTAssertNil(f.model.presentedUpdateRelease, "Opted-in background updates do not open a window")
        await f.download.finish()
        try await f.wait { f.model.isUpdateReady }
        XCTAssertEqual(f.state.installs, 0)
        let restarted = AppModel(updatePreferences: f.preferences, showsUpdateWindows: false, startsAutomaticUpdateChecks: false)
        XCTAssertTrue(restarted.automaticallyInstallsUpdates)
    }

    @MainActor func testVerifiedUpdateInstallsOnlyAfterContinuousIdleMinute() async throws {
        let f = AutomaticUpdateFixture()
        defer { f.resetPreferences() }
        try await f.prepare()
        XCTAssertTrue(f.model.hasAvailableUpdate)
        XCTAssertNil(f.model.presentedUpdateRelease)
        let now = Date()
        f.model.considerAutomaticUpdateInstallation(now: now)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(59))
        XCTAssertEqual(f.state.installs, 0)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(60))
        XCTAssertEqual(f.state.installs, 1)
        XCTAssertTrue(f.model.isUpdating)
        XCTAssertFalse(f.model.canCleanCache(f.cache))
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(120))
        XCTAssertEqual(f.state.installs, 1)
    }

    @MainActor func testVisibleWindowsAndMenuInteractionResetIdleWait() async throws {
        let f = AutomaticUpdateFixture()
        defer { f.resetPreferences() }
        try await f.prepare()
        let now = Date()
        f.model.considerAutomaticUpdateInstallation(now: now)
        f.state.windowsOpen = true
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(60))
        XCTAssertEqual(f.state.installs, 0)
        f.state.windowsOpen = false
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(100))
        f.model.setUpdatePromptContext(active: true, allowsPrompt: true)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(160))
        XCTAssertEqual(f.state.installs, 0)
        f.model.setUpdatePromptContext(active: false, allowsPrompt: true)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(200))
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(259))
        XCTAssertEqual(f.state.installs, 0)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(260))
        XCTAssertEqual(f.state.installs, 1)
    }

    @MainActor func testCleanupCanRunWhilePreparingAndPreventsInstallation() async throws {
        let f = AutomaticUpdateFixture()
        defer { f.resetPreferences() }
        f.model.automaticallyInstallsUpdates = true
        await f.model.checkForUpdates()
        try await f.wait { await f.download.calls == 1 }
        f.model.globalCaches = [f.cache]
        XCTAssertTrue(f.model.canCleanCache(f.cache))
        f.model.cleanGlobalCache(f.cache)
        try await f.wait { await f.cleanup.calls == 1 }
        await f.download.finish()
        try await f.wait { f.model.isUpdateReady }
        let now = Date()
        f.model.considerAutomaticUpdateInstallation(now: now)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(100))
        f.model.installUpdate(f.release)
        XCTAssertEqual(f.state.installs, 0)
        await f.cleanup.finish(failing: true)
        try await f.wait { !f.model.isCleaning }
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(200))
        XCTAssertEqual(f.state.installs, 0)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(260))
        XCTAssertEqual(f.state.installs, 1)
    }

    @MainActor func testTurningOffDuringDownloadPreventsAutomaticInstallationAndKeepsManualUpdate() async throws {
        let f = AutomaticUpdateFixture()
        defer { f.resetPreferences() }
        f.model.automaticallyInstallsUpdates = true
        await f.model.checkForUpdates()
        try await f.wait { await f.download.calls == 1 }
        f.model.automaticallyInstallsUpdates = false
        await f.download.finish()
        try await f.wait { f.model.isUpdateReady }
        let now = Date()
        f.model.considerAutomaticUpdateInstallation(now: now)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(100))
        XCTAssertEqual(f.state.installs, 0)
        XCTAssertTrue(f.model.hasAvailableUpdate)
        f.model.installUpdate(f.release)
        XCTAssertEqual(f.state.installs, 1)
        let count = await f.download.calls
        XCTAssertEqual(count, 1, "Manual installation must reuse the verified download")
    }

    @MainActor func testSkipAndReminderPreventAutomaticInstallation() async throws {
        for skip in [true, false] {
            let f = AutomaticUpdateFixture()
            defer { f.resetPreferences() }
            try await f.prepare()
            let now = Date()
            if skip { f.model.skipUpdateVersion(f.release) }
            else { f.model.remindUpdateTomorrow(f.release, now: now) }
            f.model.considerAutomaticUpdateInstallation(now: now)
            f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(120))
            XCTAssertEqual(f.state.installs, 0)
            f.model.requestUpdatePrompt()
            XCTAssertEqual(f.model.presentedUpdateRelease, f.release)
            f.model.installUpdate(f.release)
            XCTAssertEqual(f.state.installs, 1, "Explicit approval overrides automatic-update suppression")
        }
    }

    @MainActor func testDownloadFailureIsVisibleAndDoesNotInstallOrRetryInALoop() async throws {
        let f = AutomaticUpdateFixture()
        defer { f.resetPreferences() }
        f.model.automaticallyInstallsUpdates = true
        await f.model.checkForUpdates()
        try await f.wait { await f.download.calls == 1 }
        await f.download.finish(failing: true)
        try await f.wait { !f.model.isPreparingUpdate }
        guard case .failed = f.model.updateState else { return XCTFail("Expected a visible error") }
        XCTAssertTrue(f.model.hasAvailableUpdate)
        f.model.considerAutomaticUpdateInstallation(now: Date().addingTimeInterval(120))
        XCTAssertEqual(f.state.installs, 0)
        f.model.setUpdatePromptContext(active: true, allowsPrompt: true)
        XCTAssertEqual(f.model.presentedUpdateRelease, f.release)
        let count = await f.download.calls
        XCTAssertEqual(count, 1)
    }

    @MainActor func testInstallationFailureRetainsBadgeAndRequiresExplicitRetry() async throws {
        let f = AutomaticUpdateFixture()
        defer { f.resetPreferences() }
        try await f.prepare()
        f.state.failInstall = true
        let now = Date()
        f.model.considerAutomaticUpdateInstallation(now: now)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(60))
        guard case .failed = f.model.updateState else { return XCTFail("Expected visible installation failure") }
        XCTAssertTrue(f.model.hasAvailableUpdate)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(120))
        XCTAssertEqual(f.state.installs, 1)
        f.state.failInstall = false
        f.model.installUpdate(f.release)
        XCTAssertEqual(f.state.installs, 2)
    }

    @MainActor func testOptingOutOfReadyUpdateResetsIdleWaitBeforeNewConsent() async throws {
        let f = AutomaticUpdateFixture()
        defer { f.resetPreferences() }
        try await f.prepare()
        let now = Date()
        f.model.considerAutomaticUpdateInstallation(now: now)
        f.model.automaticallyInstallsUpdates = false
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(100))
        XCTAssertEqual(f.state.installs, 0)
        f.model.automaticallyInstallsUpdates = true
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(200))
        XCTAssertEqual(f.state.installs, 0)
        f.model.considerAutomaticUpdateInstallation(now: now.addingTimeInterval(260))
        XCTAssertEqual(f.state.installs, 1)
    }

    @MainActor func testAlreadyRunningCleanupDefersBackgroundDownloadAndChecksDoNotDuplicateIt() async throws {
        let f = AutomaticUpdateFixture()
        defer { f.resetPreferences() }
        f.model.globalCaches = [f.cache]
        f.model.cleanGlobalCache(f.cache)
        try await f.wait { await f.cleanup.calls == 1 }
        f.model.automaticallyInstallsUpdates = true
        await f.model.checkForUpdates()
        let before = await f.download.calls
        XCTAssertEqual(before, 0)
        await f.cleanup.finish(failing: true)
        try await f.wait { await f.download.calls == 1 }
        await f.model.checkForUpdates()
        let after = await f.download.calls
        XCTAssertEqual(after, 1)
        await f.download.finish()
        try await f.wait { f.model.isUpdateReady }
        await f.model.checkForUpdates()
        XCTAssertTrue(f.model.isUpdateReady)
        XCTAssertEqual(f.state.installs, 0)
    }

    @MainActor func testInstallerRevalidatesStagingBeforeLaunchingAHelper() {
        XCTAssertThrowsError(try UpdateService().launchInstaller(for: URL(fileURLWithPath: "/fixture/nonexistent/Sift.app"))) { error in
            XCTAssertEqual(error as? UpdateError, .invalidApplication)
        }
    }
}
