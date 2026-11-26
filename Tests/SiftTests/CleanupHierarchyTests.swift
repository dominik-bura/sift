import AppKit
import SwiftUI
import XCTest
@testable import Sift

private final class HierarchyPreviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

final class CleanupHierarchyTests: XCTestCase {
    func testSkippedWarningNamesSlackUpdaterWithoutExpandingDetails() {
        let location = GlobalCache.SkippedLocation(path: "/Users/demo/Library/Caches/com.tinyspeck.slackmacgap.ShipIt", reason: "Permission denied: /private/log")
        XCTAssertEqual(CleanupHierarchy.skippedName(location), "Slack updater")
        XCTAssertEqual(CleanupHierarchy.skippedSummary([location]), "Skipped Slack updater · permission denied")
        XCTAssertEqual(CleanupHierarchy.shortReason(location), "Permission denied")
        XCTAssertEqual(location.path, "/Users/demo/Library/Caches/com.tinyspeck.slackmacgap.ShipIt", "Presentation must preserve the full diagnostic path")
    }

    func testMultipleSkippedLocationsHaveSpecificFirstNameAndAccurateReason() {
        let locations = [GlobalCache.SkippedLocation(path: "/fixture/notion-updater", reason: "Permission denied"),
                         .init(path: "/fixture/other", reason: "Read error (5): /fixture/other")]
        XCTAssertEqual(CleanupHierarchy.skippedSummary(locations), "Skipped notion updater + 1 more · unreadable")
        XCTAssertEqual(CleanupHierarchy.shortReason(locations[1]), "Read error (5)")
        XCTAssertNil(CleanupHierarchy.skippedSummary([]))
    }

    func testCategoryStatusUsesConcreteSkipCountAndKeepsBusyPriority() {
        XCTAssertEqual(CleanupHierarchy.categoryStatus(skippedCount: 1, busy: false, measuring: false, attention: true), "1 location skipped")
        XCTAssertEqual(CleanupHierarchy.categoryStatus(skippedCount: 2, busy: false, measuring: false, attention: true), "2 locations skipped")
        XCTAssertEqual(CleanupHierarchy.categoryStatus(skippedCount: 1, busy: true, measuring: false, attention: true), "cleaning")
        XCTAssertEqual(CleanupHierarchy.categoryStatus(skippedCount: 1, busy: false, measuring: true, attention: true), "measuring")
        XCTAssertEqual(CleanupHierarchy.categoryStatus(skippedCount: 0, busy: false, measuring: false, attention: false), "")
    }

    @MainActor func testExpandedHierarchyFitsAndRendersWithoutActions() throws {
        let skipped = GlobalCache.SkippedLocation(path: "/Users/demo/Library/Caches/com.tinyspeck.slackmacgap.ShipIt", reason: "Permission denied: /Users/demo/Library/Caches/com.tinyspeck.slackmacgap.ShipIt/ShipIt_stdout.log")
        let caches = [GlobalCache(id: "uv", name: "uv cache", detail: "Fixture", symbolName: "bolt", state: .available(bytes: 16_000_000_000, path: "/fixture/uv")),
                      GlobalCache(id: "app-updaters", name: "App update downloads", detail: "Leftover update packages; anything changed in the last 24 hours is kept", symbolName: "arrow.down.app", state: .available(bytes: 5_750_000_000, path: "/fixture/readable"), skippedLocations: [skipped]),
                      GlobalCache(id: "dia-cache", name: "Dia caches", detail: "Browser cache only", symbolName: "app.badge", state: .available(bytes: 2_590_000_000, path: "/fixture/dia")),
                      GlobalCache(id: "codex-cache", name: "Codex app cache", detail: "Conversations stay protected", symbolName: "app.badge", state: .available(bytes: 1_720_000_000, path: "/fixture/codex"))]
        for scheme in [ColorScheme.dark, .light] {
            let view = CleanupDashboardView(inventory: .init(worktreeBytes: 0, caches: caches, docker: .unavailable("Fixture")), observation: nil,
                cleaningIDs: [], cleaningDocker: false, eligibleCount: 3,
                onClean: { _ in XCTFail("Render must not clean") }, onDocker: { XCTFail() }, onCleanEligible: { XCTFail() }, onStopUV: { _ in XCTFail() },
                expandedCategories: [.apps], expandedRows: ["app-updaters"])
                .padding(18).frame(width: 460, height: 1050, alignment: .topLeading)
                .background(scheme == .dark ? Color(white: 0.075) : Color(white: 0.96)).preferredColorScheme(scheme)
            let host = NSHostingView(rootView: view)
            let window = HierarchyPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 1050), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.contentView = nil }
            host.frame = NSRect(x: 0, y: 0, width: 460, height: 1050)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, 460, accuracy: 1)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1_000)
            if scheme == .dark, let path = ProcessInfo.processInfo.environment["SIFT_HIERARCHY_PREVIEW"] {
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
