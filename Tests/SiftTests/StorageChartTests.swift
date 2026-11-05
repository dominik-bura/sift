import AppKit
import SwiftUI
import XCTest
@testable import Sift

final class StorageChartTests: XCTestCase {
    @MainActor func testChartComponentsRenderAtMenuBarWidth() throws {
        let start = Date(timeIntervalSince1970: 1_792_396_800)
        let samples: [DiskSpaceSample] = (0..<12).map { index -> DiskSpaceSample in
            let date = start.addingTimeInterval(Double(index) * 900)
            let free: Int64 = Int64(8 + (index % 4)) * 1_000_000_000
            return DiskSpaceSample(date: date, freeBytes: free, capacity: 500_000_000_000, cleanup: index == 7)
        }
        let before = StorageMeasurement(path: "/preview", folders: [StorageFolder(path: "/preview/Worktrees", bytes: 9_000_000_000), StorageFolder(path: "/preview/Caches", bytes: 4_000_000_000)], totalBytes: 13_000_000_000, date: start, limitedAccess: false, timedOut: false)
        let after = StorageMeasurement(path: "/preview", folders: [StorageFolder(path: "/preview/Worktrees", bytes: 11_000_000_000), StorageFolder(path: "/preview/Caches", bytes: 3_000_000_000)], totalBytes: 14_000_000_000, date: start.addingTimeInterval(900), limitedAccess: false, timedOut: false)
        let preview = VStack(alignment: .leading, spacing: 18) {
            Text("Chart components · fixture preview").font(.caption).foregroundStyle(.secondary)
            StorageBlockBar(fraction: 0.85, cells: 48).frame(height: 10)
            DiskSpaceHistoryView(samples: samples)
            FolderGrowthView(current: after, previous: before)
            StorageUncertaintyKey()
            HStack {
                Text("Attributed folder size").font(.callout)
                Spacer()
                StorageBlockBar(fraction: 0.65, hatched: true, cells: 15).frame(width: 100, height: 8)
            }.padding(12).siftStorageSurface()
            StorageScanPrompt(path: StorageOverviewService.rootPath) { XCTFail("Rendering must not start a scan") }
        }.padding(18).frame(width: 460, height: 700, alignment: .topLeading)
            .background(Color(white: 0.075)).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: preview)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 700)
        host.layoutSubtreeIfNeeded()
        let bitmap: NSBitmapImageRep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        let png: Data = try XCTUnwrap(bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        if let destination = ProcessInfo.processInfo.environment["SIFT_CHART_PREVIEW_PATH"] {
            try png.write(to: URL(fileURLWithPath: destination))
        }
    }

    @MainActor func testIdleStoragePromptRendersInLightAppearanceWithoutScanning() throws {
        let preview = StorageScanPrompt(path: "/example") { XCTFail("Rendering must not start a scan") }
            .padding(18).frame(width: 460, height: 250).background(Color.white).preferredColorScheme(.light)
        let host = NSHostingView(rootView: preview)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 250)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        if let destination = ProcessInfo.processInfo.environment["SIFT_CHART_PREVIEW_PATH"] {
            try png.write(to: URL(fileURLWithPath: destination + "-light.png"))
        }
    }
}
