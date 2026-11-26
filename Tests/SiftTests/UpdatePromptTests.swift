import XCTest
import AppKit
import SwiftUI
@testable import Sift

private actor UpdateGate {
    var downloads = 0
    var continuation: CheckedContinuation<URL, Error>?
    func download() async throws -> URL {
        downloads += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func fail() { continuation?.resume(throwing: NSError(domain: "fixture", code: 1)); continuation = nil }
    func succeed() { continuation?.resume(returning: URL(fileURLWithPath: "/fixture/Sift.app")); continuation = nil }
}

@MainActor private final class InstallRecorder { var calls = 0 }

final class UpdatePromptTests: XCTestCase {
    private let release = UpdateRelease(version: "99.0.0", downloadURL: URL(string: "https://example.com/app.zip")!,
                                        checksumURL: nil, digest: nil, releasePageURL: URL(string: "https://example.com/release")!)

    @MainActor func testPromptLayoutFitsNativeWindowInBothAppearances() {
        let model = AppModel(showsUpdateWindows: false, startsAutomaticUpdateChecks: false)
        for state in [UpdateState.available(release), .downloading(release), .failed("The update could not be downloaded. Please try again when your connection is available.")] {
            model.updateState = state
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: UpdatePromptView(model: model, release: release, applicationIcon: NSImage(size: NSSize(width: 48, height: 48))).environment(\.colorScheme, scheme))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, 420)
                XCTAssertLessThanOrEqual(host.fittingSize.height, 380)
            }
        }
    }

    func testPolicyPersistsSnoozeAndSkipAndAllowsNewVersions() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var policy = UpdatePromptPolicy()
        XCTAssertTrue(policy.shouldPresent(version: "1", now: now))
        policy.presented("1")
        XCTAssertFalse(policy.shouldPresent(version: "1", now: now))
        policy.remindTomorrow("1", now: now)
        policy = try JSONDecoder().decode(UpdatePromptPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(policy.shouldPresent(version: "1", now: now.addingTimeInterval(3600)))
        XCTAssertTrue(policy.shouldPresent(version: "1", now: now.addingTimeInterval(90_000)))
        policy.skip("1")
        XCTAssertFalse(policy.shouldPresent(version: "1", now: now.addingTimeInterval(180_000)))
        policy.remindTomorrow("1", now: now)
        XCTAssertTrue(policy.shouldPresent(version: "1", now: now.addingTimeInterval(90_000)), "A manual reminder replaces a previous skip")
        XCTAssertTrue(policy.shouldPresent(version: "2", now: now))
        policy.presented("2"); policy.deferredForCleanup("2")
        XCTAssertTrue(policy.shouldPresent(version: "2", now: now))
    }

    @MainActor func testInteractionAndRestartPersistenceWithManualOverride() async throws {
        let suite = "Sift-update-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let candidate = release
        let execution = UpdateExecution(check: { candidate }, download: { _ in XCTFail("No approval"); throw CancellationError() }, install: { _ in XCTFail("No approval") })
        let model = AppModel(updates: execution, updatePreferences: preferences, showsUpdateWindows: false, startsAutomaticUpdateChecks: false)
        await model.checkForUpdates()
        XCTAssertNil(model.presentedUpdateRelease, "Background checks must not open windows")
        model.setUpdatePromptContext(active: true, allowsPrompt: false)
        XCTAssertNil(model.presentedUpdateRelease, "Do not interrupt settings or a confirmation")
        model.setUpdatePromptContext(active: true, allowsPrompt: true)
        XCTAssertEqual(model.presentedUpdateRelease, candidate)
        model.skipUpdateVersion(candidate)
        XCTAssertTrue(model.hasAvailableUpdate, "Skipping keeps the manual update badge")
        let restarted = AppModel(updates: execution, updatePreferences: preferences, showsUpdateWindows: false, startsAutomaticUpdateChecks: false)
        restarted.setUpdatePromptContext(active: true, allowsPrompt: true)
        await restarted.checkForUpdates()
        XCTAssertNil(restarted.presentedUpdateRelease)
        restarted.requestUpdatePrompt()
        XCTAssertEqual(restarted.presentedUpdateRelease, candidate)
        restarted.remindUpdateTomorrow(candidate)
        restarted.setUpdatePromptContext(active: true, allowsPrompt: true)
        XCTAssertNil(restarted.presentedUpdateRelease)
    }

    @MainActor func testUpdateBlocksCleanupAndDuplicateDownloadsAndAllowsRetry() async throws {
        let suite = "Sift-update-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let gate = UpdateGate(), candidate = release
        let model = AppModel(updates: .init(check: { candidate }, download: { _ in try await gate.download() }, install: { _ in XCTFail("Failed download must not install") }),
                             updatePreferences: preferences, showsUpdateWindows: false, startsAutomaticUpdateChecks: false)
        await model.checkForUpdates()
        model.installUpdate(candidate); model.installUpdate(candidate)
        XCTAssertTrue(model.isUpdating)
        XCTAssertFalse(model.canInstallUpdate(candidate))
        let cache = GlobalCache(id: "uv", name: "Fixture", detail: "", symbolName: "bolt", state: .available(bytes: 100, path: "/fixture/uv"))
        model.globalCaches = [cache]
        XCTAssertFalse(model.canCleanCache(cache))
        model.cleanGlobalCache(cache); model.pruneDockerImages()
        XCTAssertFalse(model.isCleaning)
        for _ in 0..<100 {
            if await gate.downloads == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let count = await gate.downloads
        XCTAssertEqual(count, 1)
        await gate.fail()
        for _ in 0..<100 {
            if !model.isUpdating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canInstallUpdate(candidate))
        model.requestUpdatePrompt()
        model.setUpdatePromptContext(active: true, allowsPrompt: false)
        XCTAssertEqual(model.presentedUpdateRelease, candidate)
    }

    @MainActor func testCleanupDefersPromptAndInstallation() async throws {
        let suite = "Sift-update-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let gate = UpdateGate(), candidate = release
        let model = AppModel(cleanup: .init(cleanCache: { _ in _ = try await gate.download() }, inspectCache: { _ in nil }, pruneDocker: { "" }, inspectDocker: { .unavailable("Fixture") }),
                             updates: .init(check: { candidate }, download: { _ in XCTFail("Cleanup running"); throw CancellationError() }, install: { _ in XCTFail("Cleanup running") }),
                             updatePreferences: preferences, showsUpdateWindows: false, startsAutomaticUpdateChecks: false)
        model.setUpdatePromptContext(active: true, allowsPrompt: true)
        await model.checkForUpdates()
        XCTAssertNotNil(model.presentedUpdateRelease)
        let cache = GlobalCache(id: "uv", name: "Fixture", detail: "", symbolName: "bolt", state: .available(bytes: 100, path: "/fixture/uv"))
        model.globalCaches = [cache]
        model.cleanGlobalCache(cache)
        XCTAssertTrue(model.isCleaning)
        XCTAssertNil(model.presentedUpdateRelease)
        model.installUpdate(candidate)
        XCTAssertFalse(model.isUpdating)
        for _ in 0..<100 {
            if await gate.downloads == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await gate.fail()
        for _ in 0..<100 {
            if !model.isCleaning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isCleaning)
        XCTAssertEqual(model.presentedUpdateRelease, candidate)
    }

    @MainActor func testOnlyApprovedCurrentReleaseInvokesInstallerAfterDownload() async throws {
        let suite = "Sift-update-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let gate = UpdateGate(), recorder = InstallRecorder(), candidate = release
        let model = AppModel(updates: .init(check: { candidate }, download: { _ in try await gate.download() }, install: { url in
            XCTAssertEqual(url.path, "/fixture/Sift.app")
            recorder.calls += 1
        }), updatePreferences: preferences, showsUpdateWindows: false, startsAutomaticUpdateChecks: false)
        await model.checkForUpdates()
        model.setUpdatePromptContext(active: true, allowsPrompt: true)
        XCTAssertEqual(recorder.calls, 0)
        let stale = UpdateRelease(version: "1.0.0", downloadURL: candidate.downloadURL, checksumURL: nil, digest: nil, releasePageURL: candidate.releasePageURL)
        model.installUpdate(stale)
        XCTAssertFalse(model.isUpdating)
        model.installUpdate(candidate)
        for _ in 0..<100 {
            if await gate.downloads == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(recorder.calls, 0)
        await gate.succeed()
        for _ in 0..<100 {
            if recorder.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(recorder.calls, 1)
    }
}
