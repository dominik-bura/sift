import AppKit
import SwiftUI
import XCTest
@testable import Sift

final class SelectionCheckboxTests: XCTestCase {
    @MainActor private func checkbox(in view: NSView) throws -> NSButton {
        if let button = view as? NSButton { return button }
        for child in view.subviews {
            if let button = try? checkbox(in: child) { return button }
        }
        throw NSError(domain: "SelectionCheckboxTests", code: 1)
    }

    @MainActor func testCheckboxReceivesCenterClickThroughGlassAndTogglesWorkspace() throws {
        let model = AppModel()
        let root = URL(fileURLWithPath: "/fixture/worktree")
        let candidates = ["node_modules", ".next"].map {
            CleanupCandidate(url: root.appendingPathComponent($0), kind: CleanupKind.supported[0], allocatedBytes: 100)
        }
        let workspace = Workspace(url: root, name: "fixture", branch: "test", repositoryID: "fixture", repositoryName: "fixture", candidates: candidates)
        model.workspaces = [workspace]
        model.selectedCandidateIDs = []
        let view = HStack {
            SelectionCheckbox(state: .off) { model.toggleWorkspaceSelection(workspace) }
            Text("Fixture worktree")
        }.padding(12).siftStorageSurface().frame(width: 300, height: 60)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        host.layoutSubtreeIfNeeded()
        let button = try checkbox(in: host)
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertEqual(button.frame.width, 30, accuracy: 1)
        for point in [NSPoint(x: button.bounds.midX, y: button.bounds.midY), NSPoint(x: 2, y: 2)] {
            let hit = try XCTUnwrap(host.hitTest(host.convert(point, from: button)))
            XCTAssertTrue(hit === button || hit.isDescendant(of: button), "The center and padding must remain clickable through glass")
        }
        button.performClick(nil)
        XCTAssertEqual(model.selectedCandidateIDs, Set(candidates.map(\.id)))
        button.performClick(nil)
        XCTAssertTrue(model.selectedCandidateIDs.isEmpty)
        model.selectedCandidateIDs = [candidates[0].id]
        button.performClick(nil)
        XCTAssertEqual(model.selectedCandidateIDs, Set(candidates.map(\.id)), "A partial workspace selection must select all its folders")
        XCTAssertEqual(model.workspaces.count, 1, "Selecting must not clean or remove the workspace")
    }

    @MainActor func testNativeStatesAndIndividualFolderSelection() throws {
        var selected = false
        var calls = 0
        let action = { selected.toggle(); calls += 1 }
        let host = NSHostingView(rootView: SelectionCheckbox(state: .off, action: action))
        host.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        host.layoutSubtreeIfNeeded()
        let button = try checkbox(in: host)
        XCTAssertEqual(button.state, .off)
        button.performClick(nil)
        XCTAssertTrue(selected)
        XCTAssertEqual(calls, 1)
        host.rootView = SelectionCheckbox(state: .mixed, action: action)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.state, .mixed)
        host.rootView = SelectionCheckbox(state: .on, action: action)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.state, .on)
        button.performClick(nil)
        XCTAssertFalse(selected)
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testDisabledCheckboxRemainsDisabled() throws {
        let host = NSHostingView(rootView: SelectionCheckbox(state: .off) { XCTFail("Disabled checkbox activated") }.disabled(true))
        host.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(try checkbox(in: host).isEnabled)
    }
}
