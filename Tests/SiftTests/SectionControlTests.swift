import AppKit
import SwiftUI
import XCTest
@testable import Sift

final class SectionControlTests: XCTestCase {
    @MainActor func testSegmentsFillAvailableWidthEqually() {
        let root = FullWidthSegmentedControl(
            labels: ["Clean up", "Storage", "Memory"], selection: .constant(0)
        ).frame(width: 424)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 424, height: 36)
        host.layoutSubtreeIfNeeded()

        func findControl(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.compactMap { findControl(in: $0) }.first
        }
        guard let control = findControl(in: host) else {
            return XCTFail("The section switcher must use a native segmented control")
        }
        XCTAssertEqual(control.frame.width, 424, accuracy: 1)
        XCTAssertEqual(control.segmentDistribution, .fillEqually)
        XCTAssertEqual(control.label(forSegment: 0), "Clean up")
        XCTAssertEqual(control.selectedSegment, 0)
    }
}
