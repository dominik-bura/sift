import AppKit
import SwiftUI
import XCTest
@testable import Sift

private final class ActivePreviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

final class CleanupDashboardTests: XCTestCase {
    @MainActor func testInventoryColorsAreDistinctMutedAndStableAcrossEmptyCategories() throws {
        let inventory = CleanupInventory(worktreeBytes: 10, caches: [cache("uv", bytes: 20)], docker: .checking)
        for appearanceName in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var colors: [String] = []
            appearance.performAsCurrentDrawingAppearance {
                for segment in inventory.segments {
                    let color = NSColor(SiftChartStyle.inventoryColor(for: segment.id)).usingColorSpace(.sRGB)!
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                    XCTAssertLessThan(channels.max()! - channels.min()!, 0.35, "Use muted category colors")
                    XCTAssertGreaterThan(channels.max()! - channels.min()!, 0.10, "Categories must not all be gray")
                    colors.append("\(color.redComponent),\(color.greenComponent),\(color.blueComponent)")
                }
            }
            XCTAssertEqual(Set(colors).count, 4, "Each category keeps a distinct color even at zero bytes")
        }
    }
    private func cache(_ id: String, bytes: Int64) -> GlobalCache {
        GlobalCache(id: id, name: id, detail: "Fixture cache", symbolName: "shippingbox", state: .available(bytes: bytes, path: "/fixture/\(id)"))
    }

    func testCategoriesMatchCleanupSources() {
        for id in ["uv", "pnpm", "bun", "yarn", "npm", "homebrew"] {
            XCTAssertEqual(CacheCategory.containing(cache(id, bytes: 1)), .packages)
        }
        for id in ["dia-cache", "codex-cache", "spark-cache"] {
            XCTAssertEqual(CacheCategory.containing(cache(id, bytes: 1)), .apps)
        }
        for id in ["xcode-build", "go", "pulumi", "simulators", "future-tool"] {
            XCTAssertEqual(CacheCategory.containing(cache(id, bytes: 1)), .developerTools)
        }
    }

    func testStoredBreakdownIncludesPrunableAndBlockedDataButNeverAddsDockerEstimate() {
        let caches = [cache("uv", bytes: 20), cache("pnpm", bytes: 30), cache("dia-cache", bytes: 40), cache("pulumi", bytes: 50)]
        let inventory = CleanupInventory(worktreeBytes: 10, caches: caches, docker: .available(reclaimableBytes: 999, detail: "Estimate"))
        XCTAssertEqual(inventory.storedBytes, 150)
        XCTAssertEqual(inventory.storedBytes(in: .packages), 50)
        XCTAssertEqual(inventory.dockerEstimate, 999)
        XCTAssertEqual(inventory.segments.map(\.name), ["Worktrees", "Packages", "Apps", "Developer tools"])
        XCTAssertFalse(caches[1].reclaimableBytes > 0)
        XCTAssertFalse(caches[3].includedInCleanAll)
        let blocked = GlobalCache(id: "uv", name: "uv", detail: "", symbolName: "bolt", state: .blocked(bytes: 20, path: "/fixture", processCount: 1))
        XCTAssertEqual(CleanupInventory(worktreeBytes: 0, caches: [blocked], docker: .checking).storedBytes, 20)
    }

    func testMissingMeasurementsArePartialNotReclaimedZeros() {
        let failed = GlobalCache(id: "uv", name: "uv", detail: "", symbolName: "bolt", state: .failed("No access"))
        let inventory = CleanupInventory(worktreeBytes: 0, caches: [failed], docker: .checking)
        XCTAssertTrue(inventory.hasUnmeasuredSources)
        XCTAssertNil(inventory.dockerEstimate)
        XCTAssertNil(CleanupObservation(operation: "test", before: nil, after: 10).freeSpaceChange)
        XCTAssertEqual(CleanupObservation(operation: "test", before: 10, after: 7).freeSpaceChange, -3)
        XCTAssertEqual(CleanupObservation(operation: "test", before: 10, after: 12).freeSpaceChange, 2)
        XCTAssertTrue(CleanupInventory(worktreeBytes: 0, caches: [], docker: .checking, worktreesUnmeasured: true).hasUnmeasuredSources)
        XCTAssertNil(failed.measuredBytes)
        XCTAssertEqual(cache("uv", bytes: 0).measuredBytes, 0)
    }

    @MainActor func testCleanupScreenRendersWithGroupedInventory() throws {
        let model = AppModel()
        let fixtureRoot = URL(fileURLWithPath: "/fixture/project")
        let candidate = CleanupCandidate(url: fixtureRoot.appendingPathComponent("node_modules"),
                                         kind: CleanupKind.supported[0], allocatedBytes: 12_000_000_000)
        model.workspaces = [Workspace(url: fixtureRoot, name: "promptic", branch: "feat/storage-redesign", repositoryID: "fixture", repositoryName: "promptic", candidates: [candidate])]
        model.lastSyncedAt = Date() // Keep the preview from starting any workspace scan.
        model.globalCaches = [
            GlobalCache(id: "uv", name: "uv cache", detail: "Downloaded package artifacts", symbolName: "bolt.fill", state: .available(bytes: 14_670_000_000, path: "/fixture/.cache/uv")),
            GlobalCache(id: "bun", name: "Bun cache", detail: "Downloaded packages", symbolName: "hare.fill", state: .available(bytes: 8_740_000_000, path: "/fixture/.bun/install/cache")),
            GlobalCache(id: "dia-cache", name: "Dia caches", detail: "Browser cache only", symbolName: "app.badge", state: .available(bytes: 4_760_000_000, path: "/fixture/Library/Caches/Dia")),
            GlobalCache(id: "pulumi", name: "Pulumi plugins", detail: "Requires individual review", symbolName: "shippingbox", state: .available(bytes: 9_430_000_000, path: "/fixture/.pulumi/plugins"))
        ]
        model.dockerState = .available(reclaimableBytes: 1_040_000_000, detail: "2 unused images")
        let view = ContentView(applicationIcon: NSImage(systemSymbolName: "line.3.horizontal.decrease.circle.fill", accessibilityDescription: "Preview icon"))
            .environmentObject(model).preferredColorScheme(.dark)
            .background(Color(white: 0.075))
        let host = NSHostingView(rootView: view)
        let window = ActivePreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 660), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 660)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        if let destination = ProcessInfo.processInfo.environment["SIFT_CLEANUP_PREVIEW_PATH"] {
            try png.write(to: URL(fileURLWithPath: destination))
        }
        XCTAssertFalse(model.isScanning, "Rendering must not start a broad scan")
    }

    @MainActor func testExpandedDashboardRendersWarningsAndObservedResult() throws {
        let examples = [
            GlobalCache(id: "uv", name: "uv cache", detail: "The lock must be released before cleanup", symbolName: "bolt.fill", state: .blocked(bytes: 6_000_000_000, path: "/fixture/.cache/uv", processCount: 2)),
            GlobalCache(id: "yarn", name: "Yarn cache", detail: "Package cache", symbolName: "shippingbox", state: .failed("Could not measure cache; check permissions")),
            GlobalCache(id: "dia-cache", name: "Dia caches", detail: "Browser cache only; profiles stay protected", symbolName: "app.badge", state: .available(bytes: 1_000_000_000, path: "/fixture/Library/Caches/Dia")),
            GlobalCache(id: "pulumi", name: "Pulumi plugins", detail: "Required plugins may download again", symbolName: "shippingbox", state: .available(bytes: 9_000_000_000, path: "/fixture/.pulumi/plugins")),
            GlobalCache(id: "simulators", name: "Unavailable simulators", detail: "No unavailable devices", symbolName: "iphone", state: .available(bytes: 0, path: "/fixture/Devices"))
        ]
        let view = CleanupDashboardView(
            inventory: CleanupInventory(worktreeBytes: 12_000_000_000, caches: examples, docker: .available(reclaimableBytes: 1_000_000_000, detail: "Unused images")),
            observation: CleanupObservation(operation: "Example cleanup", before: 7_000_000_000, after: 7_240_000_000),
            cleaningID: nil, cleaningDocker: false, isCleaning: false, eligibleCount: 1,
            onClean: { _ in XCTFail("Rendering must not execute cleanup") },
            onDocker: { XCTFail("Rendering must not execute Docker cleanup") },
            onCleanEligible: { XCTFail("Rendering must not execute bulk cleanup") },
            onStopUV: { _ in XCTFail("Rendering must not stop processes") },
            expandedCategories: Set(CacheCategory.allCases), expandedRows: ["uv", "yarn", "pulumi"]
        ).padding(18).frame(width: 460, height: 1100, alignment: .topLeading)
            .background(Color(white: 0.075)).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        let window = ActivePreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 1100), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 1100)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        if let destination = ProcessInfo.processInfo.environment["SIFT_CLEANUP_EXPANDED_PREVIEW_PATH"] {
            try png.write(to: URL(fileURLWithPath: destination))
        }
    }
}
